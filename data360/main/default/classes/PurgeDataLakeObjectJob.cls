/**
 * @description Purge of a Data Lake Object with an Ingestion API bulk delete job, as a chain of Queueable jobs.
 * Each job runs one step and enqueues the next one:
 * - START: validate the configuration, count the matching records, create the delete job
 * - QUERY_PAGE: query a page of primary keys with Data 360 SQL and upload it as a CSV file (scheduled mode)
 * - UPLOAD_FILE: read a file of primary keys and upload it (one-time file mode)
 * - POLL: wait until Data 360 has processed the job
 * - CHECK: count the records that are still there
 * Each job is its own Finalizer: an error that Apex can't catch, such as a governor limit, aborts the open job,
 * is reported, and the scheduled purge continues with the next sequence.
 */
public with sharing class PurgeDataLakeObjectJob implements Queueable, Database.AllowsCallouts, Finalizer {

	/**
	 * @description Steps of the purge
	 */
	public enum JobStep { START, QUERY_PAGE, UPLOAD_FILE, POLL, CHECK }

	//a run chains many jobs: the default maximum of 5 chained jobs of Developer and Trial orgs is raised for the run
	private static final Integer MAX_STACK_DEPTH = 300;
	//delays in minutes before a step is tried again after a 409, 429 or 5xx response
	private static final List<Integer> RETRY_DELAYS = new List<Integer>{1, 2, 5, 10};
	private static final Integer FIRST_POLL_DELAY = 3;
	private static final Integer POLL_DELAY = 5;
	private static final Integer POLL_TIMEOUT = 120;
	//the Ingestion API is eventually consistent: wait before the records are counted again
	private static final Integer CHECK_DELAY = 1;
	//a page stops early when the heap is above this ratio of its limit
	private static final Decimal MAX_HEAP_RATIO = 0.6;
	//a callout body is limited to 12 MB in asynchronous Apex, and a character can take several bytes
	@TestVisible
	private static Integer maxRequestBody = 6000000;
	//the files of a one-time run are read in memory
	public static Integer maxFileSize = 3000000;
	private static final Integer MAX_EXACT_CHECK = 50000;
	private static final Integer CHECK_SAMPLE = 2000;
	private static final Integer KEYS_PER_CHECK_QUERY = 500;
	private static final Integer KEYS_PER_CHECK_STEP = 5000;
	//a job is used only if it was created by this request: Data 360 returns the job already open on the object, if any
	private static final Integer CREATED_DATE_TOLERANCE = 120;
	private static final Set<String> RUNNING_STATUSES = new Set<String>{'Holding', 'Queued', 'Preparing', 'Processing'};
	private static final Pattern CONNECTION_NAME = Pattern.compile(
		'^(.+)_[0-9a-fA-F]{8}_[0-9a-fA-F]{4}_[0-9a-fA-F]{4}_[0-9a-fA-F]{4}_[0-9a-fA-F]{12}$');

	//in the tests, the jobs to enqueue and the chain continuations are recorded instead of being started
	@TestVisible
	private static Boolean captureInTests = false;
	@TestVisible
	private static List<PurgeDataLakeObjectJob> enqueued = new List<PurgeDataLakeObjectJob>();
	@TestVisible
	private static List<Integer> enqueueDelays = new List<Integer>();
	@TestVisible
	private static List<Integer> continuedAfter = new List<Integer>();

	@TestVisible
	private PurgeDataLakeObjectRun run;
	@TestVisible
	private JobStep step;
	private Boolean chained = false;
	private transient PurgeDataLakeObjectApi api;

	/**
	 * @description Job of a step of the run
	 * @param run State of the run
	 * @param step Step to run
	 */
	public PurgeDataLakeObjectJob(PurgeDataLakeObjectRun run, JobStep step){
		this.run = run;
		this.step = step;
	}

	/**
	 * @description Start a run: check its parameters and enqueue its first job
	 * @param run State of the run
	 * @return `Id` Id of the first job
	 */
	public static Id start(PurgeDataLakeObjectRun run){
		run.validateParameters();
		run.startedAt = Datetime.now();
		return enqueue(new PurgeDataLakeObjectJob(run, JobStep.START), 0, true);
	}

	/**
	 * @description Indicates if a purge of a Data Lake Object is running
	 * @return `Boolean` true while a PurgeDataLakeObjectJob is queued or running
	 */
	public static Boolean isRunning(){
		return [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND ApexClass.Name = 'PurgeDataLakeObjectJob'
			AND Status IN :RUNNING_STATUSES] > 0;
	}

	public void execute(QueueableContext context){
		if(context != null){
			System.attachFinalizer(this);
		}
		try {
			switch on this.step {
				when START {
					startRun();
				}
				when QUERY_PAGE {
					queryPage();
				}
				when UPLOAD_FILE {
					uploadFile();
				}
				when POLL {
					poll();
				}
				when CHECK {
					check();
				}
			}
		} catch (PurgeDataLakeObjectApi.RetryableException e) {
			retry(e.getMessage());
		} catch (Exception e) {
			fail(e.getMessage());
		}
	}

	/**
	 * @description Called after each job: an error that Apex couldn't catch is reported and ends the run
	 * @param context FinalizerContext
	 */
	public void execute(FinalizerContext context){
		if(this.run.finished){
			return;
		}
		if(context.getResult() == ParentJobResult.UNHANDLED_EXCEPTION){
			fail('Unhandled error in the ' + this.step + ' step: ' + context.getException().getMessage());
		} else if(!this.chained){
			//safety net: every step either enqueues the next one or ends the run
			fail('The ' + this.step + ' step ended without starting the next step.');
		}
	}

	/**
	 * @description START: validate the configuration, count the records, and create the delete job
	 */
	private void startRun(){
		validateConfiguration();
		if(this.run.mode == PurgeDataLakeObjectRun.RunMode.QUERY){
			this.run.matched = countRecords(true);
			if(this.run.dryRun || this.run.matched == 0){
				finish();
				return;
			}
		} else if(this.run.dryRun){
			next(JobStep.UPLOAD_FILE, 0, true);
			return;
		}
		createJob();
		next(this.run.mode == PurgeDataLakeObjectRun.RunMode.QUERY ? JobStep.QUERY_PAGE : JobStep.UPLOAD_FILE, 0, true);
	}

	/**
	 * @description Check the Data Lake Object and the Ingestion API connector with the Data 360 metadata
	 */
	private void validateConfiguration(){
		Map<String, Object> dlo = getApi().getDataLakeObject(this.run.dataLakeObject);
		if(dlo == null){
			throw configurationError('The Data Lake Object ' + this.run.dataLakeObject + ' doesn\'t exist.');
		}

		List<String> dataspaces = new List<String>();
		for(Object info : asList(dlo.get('dataSpaceInfo'))){
			dataspaces.add((String) ((Map<String, Object>) info).get('name'));
		}
		if(!dataspaces.contains(this.run.dataspace)){
			throw configurationError(this.run.dataLakeObject + ' isn\'t in the data space ' + this.run.dataspace
				+ ' (data spaces of the object: ' + String.join(dataspaces, ', ') + ').');
		}

		String primaryKey;
		for(Object field : asList(dlo.get('fields'))){
			Map<String, Object> fieldInfo = (Map<String, Object>) field;
			if(fieldInfo.get('isPrimaryKey') == true){
				primaryKey = (String) fieldInfo.get('name');
			}
		}
		if(primaryKey == null || !isSameField(primaryKey, this.run.primaryKeyField)){
			throw configurationError('The primary key of ' + this.run.dataLakeObject + ' is ' + primaryKey + ', not '
				+ this.run.primaryKeyField + ' (PrimaryKeyField__c).');
		}
		this.run.primaryKeyField = primaryKey;
		this.run.recordModifiedField = (String) dlo.get('recordModifiedFieldName');

		Map<String, Object> connection = findConnection();
		if(connection == null){
			throw configurationError('No Ingestion API connector is named ' + this.run.connector + '. ' + getIngestionOnlyMessage());
		}
		this.run.connector = getSourceName((String) connection.get('name'));

		Boolean fedByConnector = false;
		for(Object stream : getApi().getDataStreams((String) connection.get('name'))){
			Map<String, Object> streamInfo = (Map<String, Object>) stream;
			Map<String, Object> dloInfo = (Map<String, Object>) streamInfo.get('dataLakeObjectInfo');
			Map<String, Object> connectorInfo = (Map<String, Object>) streamInfo.get('connectorInfo');
			if(dloInfo != null && this.run.dataLakeObject.equalsIgnoreCase((String) dloInfo.get('name'))
				&& connectorInfo != null && connectorInfo.get('connectorType') == 'IngestApi'){
				fedByConnector = true;
			}
		}
		if(!fedByConnector){
			throw configurationError(this.run.dataLakeObject + ' isn\'t fed by a data stream of the Ingestion API connector '
				+ this.run.connector + '. ' + getIngestionOnlyMessage());
		}
	}

	private Map<String, Object> findConnection(){
		for(Object connection : getApi().getIngestionConnections()){
			Map<String, Object> connectionInfo = (Map<String, Object>) connection;
			String name = (String) connectionInfo.get('name');
			String label = (String) connectionInfo.get('label');
			if(name != null && (name.equalsIgnoreCase(this.run.connector) || getSourceName(name).equalsIgnoreCase(this.run.connector)
				|| (label != null && label.equalsIgnoreCase(this.run.connector)))){
				return connectionInfo;
			}
		}
		return null;
	}

	/**
	 * @description Returns the name used by the Ingestion API: the name of the connection without its generated suffix
	 * @param connectionName Name of the connection, for example Ecomm_33e7e8ab_4e45_48ae_ab81_a09a9810a02b
	 * @return `String` Source name, for example Ecomm
	 */
	@TestVisible
	private static String getSourceName(String connectionName){
		Matcher m = CONNECTION_NAME.matcher(connectionName);
		return m.matches() ? m.group(1) : connectionName;
	}

	private static String getIngestionOnlyMessage(){
		return 'Only the Data Lake Objects of Ingestion API data streams can be purged: '
			+ 'the data streams of the Web and Mobile SDK, CRM and other connectors don\'t support record deletion.';
	}

	/**
	 * @description Create the delete job. Data 360 accepts one open job per object, and returns that job
	 * instead of creating a new one: a job that this request didn't create is not used.
	 */
	private void createJob(){
		Datetime requestedAt = Datetime.now();
		Map<String, Object> job;
		try {
			job = getApi().createDeleteJob(this.run.connector, this.run.sourceObject);
		} catch (PurgeDataLakeObjectApi.RetryableException e) {
			throw e;
		} catch (PurgeDataLakeObjectApi.ApiException e) {
			if(e.statusCode == 404){
				throw configurationError('The Ingestion API connector ' + this.run.connector + ' has no object '
					+ this.run.sourceObject + ' (IngestionObject__c).');
			}
			throw e;
		}
		String operation = (String) job.get('operation');
		String state = (String) job.get('state');
		Datetime createdDate = parseDatetime((String) job.get('createdDate'));
		if(operation != 'delete' || state != 'Open' || createdDate == null || createdDate < requestedAt.addSeconds(-CREATED_DATE_TOLERANCE)){
			throw new PurgeDataLakeObjectApi.RetryableException('The ' + operation + ' job ' + job.get('id') + ' (' + state + ', created on '
				+ job.get('createdDate') + ') is open on the object ' + this.run.sourceObject + ' of the connector ' + this.run.connector
				+ ': Data 360 accepts one open job per object, and the purge only uses a job it created.');
		}
		this.run.jobId = (String) job.get('id');
		this.run.jobState = state;
		if(String.isNotBlank(this.run.recordModifiedField)){
			//the deletion must be more recent than the record: the current time is sent as record version
			this.run.recordVersion = Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');
		}
	}

	/**
	 * @description QUERY_PAGE: read the next page of primary keys of the query, and upload it
	 */
	private void queryPage(){
		sfsqlquery.SqlRowIterator rows = this.run.queryId == null
			? sfsqlquery.SqlStatement.create(getPrimaryKeyQuery(), this.run.dataspace).execute()
			: new sfsqlquery.SqlRowIterator(sfsqlquery.QueryHandle.create(this.run.queryId, this.run.dataspace).withOffset(this.run.offset));
		List<String> lines = new List<String>();
		Integer read = 0;
		Integer maxHeap = (Integer) (Limits.getLimitHeapSize() * MAX_HEAP_RATIO);
		while(read < this.run.chunkSize && rows.hasNext()){
			addLine(lines, rows.next().getString('v'));
			read++;
			if(Math.mod(read, 1000) == 0 && Limits.getHeapSize() > maxHeap){
				break;
			}
		}
		if(this.run.queryId == null){
			this.run.queryId = rows.getQueryId();
		}
		Boolean more = rows.hasNext();
		rows = null;
		this.run.filesOfLastPage = 0;
		uploadLines(lines);
		this.run.queried += read;
		this.run.offset += read;

		if(more && this.run.files + Math.max(1, this.run.filesOfLastPage) <= PurgeDataLakeObjectRun.MAX_FILES){
			next(JobStep.QUERY_PAGE, 0, true);
		} else{
			if(more){
				this.run.warnings.add('The Ingestion API job reached its limit of ' + PurgeDataLakeObjectRun.MAX_FILES
					+ ' files: the remaining records will be purged at the next run.');
			}
			closeJob();
		}
	}

	/**
	 * @description UPLOAD_FILE: read the next file of primary keys, and upload it (or only count its keys for a dry run)
	 */
	private void uploadFile(){
		List<String> keys = readPrimaryKeys(this.run.contentDocumentIds.get(this.run.fileIndex));
		if(!this.run.dryRun){
			List<String> lines = new List<String>();
			for(String key : keys){
				addLine(lines, key);
				if(lines.size() == this.run.chunkSize){
					uploadLines(lines);
					lines = new List<String>();
				}
			}
			uploadLines(lines);
		}
		this.run.queried += keys.size();
		this.run.fileIndex++;

		if(this.run.fileIndex < this.run.contentDocumentIds.size()){
			next(JobStep.UPLOAD_FILE, 0, true);
		} else if(this.run.dryRun){
			finish();
		} else{
			closeJob();
		}
	}

	/**
	 * @description Close the job so that Data 360 processes it, continue the scheduled purge, and wait for the result
	 */
	private void closeJob(){
		if(this.run.submitted == 0){
			//nothing to delete: the empty job is discarded
			abortOpenJob();
			finish();
			return;
		}
		Map<String, Object> job = getApi().closeJob(this.run.jobId);
		this.run.jobState = (String) job.get('state');
		this.run.closedAt = Datetime.now();
		continueChain();
		next(JobStep.POLL, FIRST_POLL_DELAY, true);
	}

	/**
	 * @description POLL: check the state of the job until it is processed, or until the timeout
	 */
	private void poll(){
		Map<String, Object> job = getApi().getJob(this.run.jobId);
		this.run.jobState = (String) job.get('state');
		Object processingTime = job.get('totalProcessingTime');
		this.run.processingTime = processingTime != null ? Long.valueOf(String.valueOf(processingTime)) : null;
		switch on this.run.jobState {
			when 'JobComplete' {
				next(JobStep.CHECK, CHECK_DELAY, true);
			}
			when 'Failed', 'Aborted' {
				this.run.errors.add('The Ingestion API job ' + this.run.jobId + ' ended with the state ' + this.run.jobState + '.');
				finish();
			}
			when else {
				if(this.run.closedAt.addMinutes(POLL_TIMEOUT) < Datetime.now()){
					this.run.warnings.add('The Ingestion API job ' + this.run.jobId + ' is still ' + this.run.jobState + ' after '
						+ POLL_TIMEOUT + ' minutes. Data 360 keeps processing it: check its state later.');
					finish();
				} else{
					next(JobStep.POLL, POLL_DELAY, true);
				}
			}
		}
	}

	/**
	 * @description CHECK: count the records that were not deleted. Scheduled mode: the records that still match the WHERE clause.
	 * File mode: the primary keys that are still present, all of them up to 50,000 keys, a sample of 2,000 keys otherwise.
	 */
	private void check(){
		if(this.run.mode == PurgeDataLakeObjectRun.RunMode.QUERY){
			this.run.stillPresent = countRecords(false);
			finish();
			return;
		}
		if(this.run.checkTarget == null){
			this.run.checkTarget = this.run.submitted <= MAX_EXACT_CHECK ? this.run.submitted : CHECK_SAMPLE;
			this.run.stillPresent = 0;
		}
		List<String> keys = new List<String>();
		while(keys.size() < KEYS_PER_CHECK_STEP && this.run.checked + keys.size() < this.run.checkTarget
			&& this.run.checkFileIndex < this.run.contentDocumentIds.size()){
			List<String> fileKeys = readPrimaryKeys(this.run.contentDocumentIds.get(this.run.checkFileIndex));
			while(this.run.checkLineOffset < fileKeys.size() && keys.size() < KEYS_PER_CHECK_STEP
				&& this.run.checked + keys.size() < this.run.checkTarget){
				keys.add(fileKeys.get(this.run.checkLineOffset));
				this.run.checkLineOffset++;
			}
			if(this.run.checkLineOffset >= fileKeys.size()){
				this.run.checkFileIndex++;
				this.run.checkLineOffset = 0;
			}
		}
		for(Integer i = 0; i < keys.size(); i += KEYS_PER_CHECK_QUERY){
			List<String> slice = new List<String>();
			for(Integer j = i; j < Math.min(i + KEYS_PER_CHECK_QUERY, keys.size()); j++){
				slice.add(keys.get(j));
			}
			this.run.stillPresent += countKeys(slice);
		}
		this.run.checked += keys.size();
		if(this.run.checked < this.run.checkTarget && this.run.checkFileIndex < this.run.contentDocumentIds.size()){
			next(JobStep.CHECK, 0, false);
		} else{
			finish();
		}
	}

	/**
	 * @description Returns the number of records that match the WHERE clause
	 * @param validation true when the WHERE clause is checked at the start of the run
	 * @return `Long` Number of records
	 */
	private Long countRecords(Boolean validation){
		String sql = 'SELECT CAST(COUNT(*) AS VARCHAR) AS "v" FROM ' + quoteIdentifier(this.run.dataLakeObject)
			+ ' WHERE ' + this.run.whereClause;
		try {
			return getSingleValue(sql);
		} catch (Exception e) {
			if(!validation){
				throw e;
			}
			throw configurationError('The records to delete could not be counted: ' + e.getMessage()
				+ '. WhereClauseToBeDeleted__c uses the Data 360 SQL syntax, with the field API names in double quotes, '
				+ 'for example "createdDate__c" < current_date - interval \'365\' day.');
		}
	}

	private Long countKeys(List<String> keys){
		List<String> values = new List<String>();
		for(String key : keys){
			values.add('\'' + key.replace('\'', '\'\'') + '\'');
		}
		return getSingleValue('SELECT CAST(COUNT(*) AS VARCHAR) AS "v" FROM ' + quoteIdentifier(this.run.dataLakeObject)
			+ ' WHERE CAST(' + quoteIdentifier(this.run.primaryKeyField) + ' AS VARCHAR) IN (' + String.join(values, ', ') + ')');
	}

	private Long getSingleValue(String sql){
		sfsqlquery.SqlRowIterator rows = sfsqlquery.SqlStatement.create(sql, this.run.dataspace).execute();
		String value = rows.hasNext() ? rows.next().getString('v') : null;
		return String.isBlank(value) ? 0 : Long.valueOf(value);
	}

	private String getPrimaryKeyQuery(){
		return 'SELECT CAST(' + quoteIdentifier(this.run.primaryKeyField) + ' AS VARCHAR) AS "v" FROM '
			+ quoteIdentifier(this.run.dataLakeObject) + ' WHERE ' + this.run.whereClause;
	}

	/**
	 * @description Returns the primary keys of a file: one key per line, after a first line that must be the primary key field
	 * @param contentDocumentId Id of the file
	 * @return `List<String>` Primary keys, without the empty lines
	 */
	@TestVisible
	private List<String> readPrimaryKeys(Id contentDocumentId){
		List<ContentVersion> versions = [SELECT Id, Title, ContentSize FROM ContentVersion
			WHERE ContentDocumentId = :contentDocumentId AND IsLatest = true];
		if(versions.isEmpty()){
			throw configurationError('The file ' + contentDocumentId + ' doesn\'t exist or isn\'t shared with the running user.');
		}
		ContentVersion version = versions.get(0);
		if(version.ContentSize > maxFileSize){
			throw configurationError('The file "' + version.Title + '" is larger than ' + (maxFileSize / 1000000)
				+ ' MB: split it into several files.');
		}
		String content = [SELECT VersionData FROM ContentVersion WHERE Id = :version.Id].VersionData.toString();
		String byteOrderMark = String.fromCharArray(new List<Integer>{65279});
		List<String> lines = content.removeStart(byteOrderMark).split('\r?\n');
		content = null;

		String header = unquote(lines.isEmpty() ? '' : lines.get(0).trim());
		if(!isSameField(header, this.run.primaryKeyField)){
			throw configurationError('The first line of the file "' + version.Title + '" must be the primary key field '
				+ this.run.primaryKeyField + ', alone (found: ' + header + ').');
		}
		List<String> keys = new List<String>();
		for(Integer i = 1; i < lines.size(); i++){
			String key = unquote(lines.get(i).trim());
			if(String.isNotBlank(key)){
				keys.add(key);
			}
		}
		return keys;
	}

	/**
	 * @description Add a line of the CSV: the primary key, and the record version when the Data Lake Object has a record modified field
	 */
	private void addLine(List<String> lines, String key){
		if(String.isBlank(key)){
			return;
		}
		lines.add(escapeCsv(key) + (String.isNotBlank(this.run.recordVersion) ? ',' + this.run.recordVersion : ''));
	}

	/**
	 * @description Upload the lines as one CSV file, or as several files when the body would be too large
	 * @param lines Lines of the CSV, without header
	 */
	private void uploadLines(List<String> lines){
		if(lines.isEmpty()){
			return;
		}
		String csv = String.join(lines, '\n') + '\n';
		if(csv.length() > maxRequestBody && lines.size() > 1){
			csv = null;
			Integer half = lines.size() / 2;
			List<String> firstHalf = new List<String>();
			List<String> secondHalf = new List<String>();
			for(Integer i = 0; i < lines.size(); i++){
				(i < half ? firstHalf : secondHalf).add(lines.get(i));
			}
			uploadLines(firstHalf);
			uploadLines(secondHalf);
			return;
		}
		if(this.run.files >= PurgeDataLakeObjectRun.MAX_FILES){
			throw configurationError('The Ingestion API job can\'t receive more than ' + PurgeDataLakeObjectRun.MAX_FILES
				+ ' files: use fewer or larger files, or a larger chunk size.');
		}
		getApi().uploadCsv(this.run.jobId, csv);
		this.run.files++;
		this.run.filesOfLastPage++;
		this.run.submitted += lines.size();
	}

	/**
	 * @description Enqueue the job of the next step
	 * @param nextStep Step to run
	 * @param delay Minimum delay in minutes before the job runs
	 * @param resetAttempts true when the step succeeded: the retries start again from the first delay
	 */
	private void next(JobStep nextStep, Integer delay, Boolean resetAttempts){
		if(resetAttempts){
			this.run.attempts = 0;
		}
		this.chained = true;
		enqueue(new PurgeDataLakeObjectJob(this.run, nextStep), delay, false);
	}

	private static Id enqueue(PurgeDataLakeObjectJob job, Integer delay, Boolean first){
		if(Test.isRunningTest() && captureInTests){
			enqueued.add(job);
			enqueueDelays.add(delay);
			return null;
		}
		AsyncOptions options = new AsyncOptions();
		if(first){
			options.MaximumQueueableStackDepth = MAX_STACK_DEPTH;
		}
		if(delay > 0){
			options.MinimumQueueableDelayInMinutes = delay;
		}
		return System.enqueueJob(job, options);
	}

	/**
	 * @description Run the same step again later, or end the run when the retries are exhausted
	 * @param message Error of the last attempt
	 */
	private void retry(String message){
		if(this.run.attempts < RETRY_DELAYS.size()){
			Integer delay = RETRY_DELAYS.get(this.run.attempts);
			this.run.attempts++;
			System.debug(LoggingLevel.WARN, 'The ' + this.step + ' step is tried again in ' + delay + ' minute(s): ' + message);
			next(this.step, delay, false);
		} else{
			fail(message + ' (after ' + RETRY_DELAYS.size() + ' retries)');
		}
	}

	/**
	 * @description End the run with an error: the open job is aborted, so that nothing is deleted
	 * @param message Error
	 */
	private void fail(String message){
		this.run.errors.add(message);
		abortOpenJob();
		finish();
	}

	private void abortOpenJob(){
		if(this.run.jobId == null || this.run.closedAt != null || this.run.jobState == 'Aborted'){
			return;
		}
		try {
			getApi().abortJob(this.run.jobId);
			this.run.jobState = 'Aborted';
		} catch (Exception e) {
			this.run.errors.add('The open job ' + this.run.jobId + ' could not be aborted (' + e.getMessage()
				+ '): Data 360 deletes the open jobs after 7 days.');
		}
	}

	/**
	 * @description End the run: continue the scheduled purge if it wasn't done yet, and send the report
	 */
	private void finish(){
		if(this.run.finished){
			return;
		}
		this.run.finished = true;
		continueChain();
		PurgeDataLakeObjectReport.send(this.run);
	}

	/**
	 * @description Start the purge of the next sequence of the scheduled purge, once per run
	 */
	private void continueChain(){
		if(this.run.mode != PurgeDataLakeObjectRun.RunMode.QUERY || this.run.chainContinued || this.run.sequence == null){
			return;
		}
		this.run.chainContinued = true;
		continuedAfter.add(this.run.sequence);
		if(Test.isRunningTest() && captureInTests){
			return;
		}
		try {
			PurgeSObjectBatch.startSequenceAfter(this.run.sequence);
		} catch (Exception e) {
			this.run.errors.add('The purge of the next sequence could not be started: ' + e.getMessage());
		}
	}

	private PurgeDataLakeObjectApi getApi(){
		if(this.api == null){
			this.api = new PurgeDataLakeObjectApi();
		}
		return this.api;
	}

	private static PurgeDataLakeObjectRun.ConfigurationException configurationError(String message){
		return new PurgeDataLakeObjectRun.ConfigurationException(message);
	}

	private static List<Object> asList(Object value){
		return value instanceof List<Object> ? (List<Object>) value : new List<Object>();
	}

	/**
	 * @description Compare two field names, with or without the __c suffix of the Data Lake Object fields
	 */
	@TestVisible
	private static Boolean isSameField(String first, String second){
		if(String.isBlank(first) || String.isBlank(second)){
			return false;
		}
		return first.trim().toLowerCase().removeEnd('__c') == second.trim().toLowerCase().removeEnd('__c');
	}

	private static String quoteIdentifier(String identifier){
		return '"' + identifier.replace('"', '""') + '"';
	}

	@TestVisible
	private static String escapeCsv(String value){
		if(value.contains(',') || value.contains('"') || value.contains('\n') || value.contains('\r')){
			return '"' + value.replace('"', '""') + '"';
		}
		return value;
	}

	private static String unquote(String value){
		if(value.length() >= 2 && value.startsWith('"') && value.endsWith('"')){
			return value.substring(1, value.length() - 1).replace('""', '"');
		}
		return value;
	}

	private static Datetime parseDatetime(String value){
		if(String.isBlank(value) || value.length() < 19){
			return null;
		}
		try {
			return Datetime.valueOfGmt(value.left(19).replace('T', ' '));
		} catch (Exception e) {
			return null;
		}
	}
}
