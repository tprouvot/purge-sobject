/**
 * @description This class is used to clean the database by performing records deletion
 */
public with sharing class PurgeSObjectBatch implements Database.Batchable<SObject>, Database.Stateful, Database.RaisesPlatformEvents{

	//maximum length of the Records__c field, used to split the records between several events when published per chunk
	@TestVisible
	private static Integer recordsMaxLength = PurgeSObjectBatch__e.Records__c.getDescribe().getLength();
	//batch size used when BatchSize__c is not set in the CMDT
	private static final Integer DEFAULT_BATCH_SIZE = 200;
	//maximum number of distinct deletion errors listed in the summary email
	private static final Integer MAX_ERROR_SAMPLES = 10;
	//Lightning email template of the summary email, customizable in the Email Templates tab
	private static final String SUMMARY_EMAIL_TEMPLATE = 'PurgeSObject_Summary';
	//PurgeSObjectHandler implementations of the optional modules, used only when they are deployed (data360 folder)
	private static final List<String> HANDLER_CLASSES = new List<String>{'PurgeDataLakeObjectHandler'};

	//settings used instead of the custom metadata records, sorted by sequence: set by the tests
	@TestVisible
	private static List<PurgeSObjectSetting__mdt> settingsOverride;
	//handlers used instead of HANDLER_CLASSES: set by the tests
	@TestVisible
	private static List<PurgeSObjectHandler> handlersOverride;
	private static List<PurgeSObjectHandler> handlers;

	private Integer sequence;
	private Integer lastSequence;
	@TestVisible
	private Integer batchSize;
	@TestVisible
	private Boolean publishPeOk;
	@TestVisible
	private Boolean publishPeKo;
	@TestVisible
	private Boolean publishPePerChunk;
	@TestVisible
	private String externalId;
	private String externalToBeDeleted;
	@TestVisible
	private String whereClause;

	@TestVisible
	private String sobjectName;
	@TestVisible
	private Boolean dryRun = false;
	//setting of the current sequence, with all its fields, passed to the handler of an optional module
	private PurgeSObjectSetting__mdt setting;
	//index in getHandlers() of the handler that purges the setting, null when PurgeSObjectBatch purges it
	@TestVisible
	private Integer handlerIndex;

	//summary of the run, kept between the chunks and sent by email when there are errors
	@TestVisible
	private Integer matchedCount = 0;
	@TestVisible
	private Integer deletedCount = 0;
	@TestVisible
	private Integer failedCount = 0;
	@TestVisible
	private List<String> errorSamples = new List<String>();
	@TestVisible
	private List<String> runErrors = new List<String>();

	/**
	 * @description Constructor with parameters, called by the finish method
	 * @param  sequence		Defines the Object Sequence to delete in this instance
	 */
	public PurgeSObjectBatch(Integer sequence){
		setParams(sequence);
	}

	/**
	 * @description Constructor without parameters, called by the schedulable class
	 */
	public PurgeSObjectBatch() {
		setParams(null);
	}

	/**
	 * @description Build the query with the custom metadata parameters and the SObject name
	 * @param  BC BatchableContext
	 * @return    QueryLocator
	 */
	public Database.QueryLocator start(Database.BatchableContext BC){
		//no configuration left to process
		if(String.isBlank(this.sobjectName)){
			return getEmptyQueryLocator();
		}
		if(this.handlerIndex != null){
			//purged by the handler of an optional module, which is started in finish
			return getEmptyQueryLocator();
		}
		try {
			String extId = getExternalIdValue();
			String query = 'SELECT Id' + extId + ' FROM ' + String.escapeSingleQuotes(this.sobjectName) + ' WHERE ' + getWhereClause();
			return Database.getQueryLocator(query);
		} catch (Exception e) {
			//an invalid configuration must not stop the chain: finish is still called and the next sequence is processed
			this.runErrors.add('The records to delete could not be queried: ' + e.getMessage());
			publishConfigurationError(e.getMessage());
			return getEmptyQueryLocator();
		}
	}

	public void execute(Database.BatchableContext BC, List<SObject> scope){
		//dry run: count the matching records, delete nothing and publish no event
		if(this.dryRun){
			this.matchedCount += scope.size();
			return;
		}
		SObjectType sObjType = ((SObject) Type.forName(this.sobjectName).newInstance()).getSObjectType();
		if (sObjType.getDescribe().isDeletable()) {
			List<Database.DeleteResult> drList = Database.delete(scope, false);
			recordResults(drList);
			if(this.publishPeOk || this.publishPeKo){
				publishPlatformEventIfEnabled(drList, scope);
			}
		}
	}

	/**
	 * @description Call the PurgeSObjectBatch to handle the deletion of the next records Object to parse,
	 * then send the summary of the run by email if there were errors
	 * @param  BC BatchableContext
	 */
	public void finish(Database.BatchableContext BC){
		//the handler of an optional module purges the setting asynchronously, and continues the chain when it is done
		Boolean handedOff = this.handlerIndex != null && this.runErrors.isEmpty() && startHandler();

		//call the batch only if the Object list is not the last one
		if(!handedOff && sequence != null && sequence < lastSequence){
			try {
				startSequenceAfter(sequence);
			} catch (Exception e) {
				this.runErrors.add('The purge of the next sequence could not be started: ' + e.getMessage());
			}
		}

		try {
			AsyncApexJob job = [SELECT NumberOfErrors, ExtendedStatus FROM AsyncApexJob WHERE Id = :BC.getJobId()];
			Messaging.SingleEmailMessage email = getErrorSummaryEmail(job.NumberOfErrors, job.ExtendedStatus);
			if(email != null){
				Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{email});
			}
		} catch (Exception e) {
			//for example when the email deliverability of the org doesn't allow Apex emails
			System.debug(LoggingLevel.ERROR, 'Error : the summary email could not be sent - ' + e.getMessage());
		}
	}

	/**
	 * @description Returns the batch size from the CMDT, 200 if not set
	 * @return `Integer` Number of records deleted per chunk
	 */
	public Integer getBatchSize(){
		return this.batchSize != null ? this.batchSize : DEFAULT_BATCH_SIZE;
	}

	/**
	 * @description Start the purge of the setting that follows a sequence. Used by finish, and by the handlers of the optional
	 * modules to continue the chain when they are done with their setting
	 * @param sequence Sequence of the setting that was just purged
	 * @return `Id` Id of the batch job, null when there is no setting after this sequence
	 */
	public static Id startSequenceAfter(Integer sequence){
		PurgeSObjectBatch nextBatch = new PurgeSObjectBatch(sequence);
		if(String.isBlank(nextBatch.sobjectName)){
			return null;
		}
		return Database.executeBatch(nextBatch, nextBatch.getBatchSize());
	}

	/**
	 * @description Returns the handlers of the optional modules that are deployed in the org. A class that doesn't exist,
	 * or that doesn't implement PurgeSObjectHandler, is ignored.
	 * @return `List<PurgeSObjectHandler>` Handlers, empty when no optional module is deployed
	 */
	public static List<PurgeSObjectHandler> getHandlers(){
		if(handlersOverride != null){
			return handlersOverride;
		}
		if(handlers == null){
			handlers = new List<PurgeSObjectHandler>();
			for(String className : HANDLER_CLASSES){
				try {
					Type handlerType = Type.forName(className);
					Object handler = handlerType != null ? handlerType.newInstance() : null;
					if(handler instanceof PurgeSObjectHandler){
						handlers.add((PurgeSObjectHandler) handler);
					}
				} catch (Exception e) {
					System.debug(LoggingLevel.WARN, 'The handler ' + className + ' is ignored: ' + e.getMessage());
				}
			}
		}
		return handlers;
	}

	/**
	 * @description Returns the index of the handler that purges a setting
	 * @param setting Custom metadata record
	 * @return `Integer` Index in getHandlers(), null when PurgeSObjectBatch purges the setting itself
	 */
	private static Integer findHandler(PurgeSObjectSetting__mdt setting){
		List<PurgeSObjectHandler> available = getHandlers();
		for(Integer i = 0; i < available.size(); i++){
			if(available.get(i).handles(setting)){
				return i;
			}
		}
		return null;
	}

	/**
	 * @description Start the purge of the setting with the handler of its optional module
	 * @return `Boolean` true when the handler started the purge and will continue the chain, false otherwise
	 */
	private Boolean startHandler(){
		try {
			getHandlers().get(this.handlerIndex).start(this.setting);
			return true;
		} catch (Exception e) {
			String message = 'The purge of ' + this.sobjectName + ' could not be started: ' + e.getMessage();
			this.runErrors.add(message);
			publishConfigurationError(message);
			return false;
		}
	}

	/**
	 * @description Set the parameters of the batch: the sobjectName to parse and its sequence
	 * @param  sequence Object order of execution
	 */
	private void setParams(Integer sequence){
		//get the next sequences to avoid issue with missing numbers
		List<PurgeSObjectSetting__mdt> settings = new List<PurgeSObjectSetting__mdt>();
		for(PurgeSObjectSetting__mdt setting : getAllSettings()){
			//if param is null it means the method was called from the scheduled job: start with the first sequence
			if(sequence == null || setting.Sequence__c > sequence){
				settings.add(setting);
			}
		}

		//nothing left to purge: start returns no record and finish does not call another batch
		if(settings.isEmpty()){
			return;
		}

		//store the lastIndex to end the process
		if(lastSequence == null){
			//since the list is sorted by sequence, the last index is the last sequence
			this.lastSequence = Integer.valueOf(settings.get(settings.size() - 1).Sequence__c);
		}
		//use the first item of the list
		PurgeSObjectSetting__mdt sett = settings.get(0);
		this.setting = sett;
		this.sequence = Integer.valueOf(sett.Sequence__c);
		this.sobjectName = sett.SObjectApiName__c;
		this.dryRun = sett.DryRun__c == true;
		this.handlerIndex = findHandler(sett);
		this.batchSize = sett.BatchSize__c != null ? Integer.valueOf(sett.BatchSize__c) : null;
		this.publishPeOk = sett.PublishPlatformEventOk__c;
		this.publishPeKo = sett.PublishPlatformEventKo__c;
		this.publishPePerChunk = sett.PublishPlatformEventPerChunk__c;
		this.externalId = sett.PlatformEventExternalId__c;
		this.externalToBeDeleted = sett.ExternalToBeDeletedField__c;
		this.whereClause = sett.WhereClauseToBeDeleted__c;
	}

	/**
	 * @description Returns all the settings sorted by sequence, with all their fields: the fields added by an optional module
	 * exist only when the module is deployed, so they are read with a dynamic query
	 * @return `List<PurgeSObjectSetting__mdt>` Settings sorted by sequence
	 */
	private static List<PurgeSObjectSetting__mdt> getAllSettings(){
		if(settingsOverride != null){
			return settingsOverride;
		}
		//use SOQL instead of getAll(): getAll() only returns the first 255 characters of WhereClauseToBeDeleted__c
		List<String> fields = new List<String>(Schema.SObjectType.PurgeSObjectSetting__mdt.fields.getMap().keySet());
		return Database.query('SELECT ' + String.join(fields, ', ') + ' FROM PurgeSObjectSetting__mdt ORDER BY Sequence__c');
	}

	/**
	 * @description Count the deleted and failed records, and keep the first distinct deletion errors for the summary
	 * @param drList List<Database.DeleteResult>
	 */
	@TestVisible
	private void recordResults(List<Database.DeleteResult> drList){
		for(Database.DeleteResult dr : drList){
			if(dr.isSuccess()){
				this.deletedCount++;
			} else{
				this.failedCount++;
				String error = getError(dr.getErrors());
				if(this.errorSamples.size() < MAX_ERROR_SAMPLES && !this.errorSamples.contains(error)){
					this.errorSamples.add(error);
				}
			}
		}
	}

	/**
	 * @description Returns the summary of the run to send by email to the running user (who ran or scheduled the purge),
	 * or null when there was no error. A dry run always returns its summary, unless the handler of an optional module
	 * purges the setting: the module reports its own dry run.
	 * @param failedChunks Number of chunks that failed with an unhandled error
	 * @param firstChunkError Error of the first chunk that failed
	 * @return `Messaging.SingleEmailMessage` Summary email, null when there was no error
	 */
	@TestVisible
	private Messaging.SingleEmailMessage getErrorSummaryEmail(Integer failedChunks, String firstChunkError){
		Boolean hasErrors = this.failedCount > 0 || !this.runErrors.isEmpty() || failedChunks > 0;
		Boolean isCoreDryRun = this.dryRun && this.handlerIndex == null;
		if(!hasErrors && !isCoreDryRun){
			return null;
		}

		List<String> lines = new List<String>();
		String subject;
		if(isCoreDryRun){
			subject = 'Dry run of the purge of ' + this.sobjectName + (hasErrors ? ' completed with errors' : '');
			lines.add('Dry run of the purge of ' + this.sobjectName + ': no record was deleted.');
			lines.add('');
			lines.add('Records matching the delete logic: ' + this.matchedCount);
		} else{
			subject = 'Purge of ' + this.sobjectName + ' completed with errors';
			lines.add('The purge of ' + this.sobjectName + ' completed with errors.');
			lines.add('');
			lines.add('Records deleted: ' + this.deletedCount);
			lines.add('Records not deleted: ' + this.failedCount);
		}
		if(failedChunks > 0){
			lines.add('Chunks not processed because of an unhandled error: ' + failedChunks + ' (first error: ' + firstChunkError + ')');
		}
		if(!this.runErrors.isEmpty()){
			lines.add('');
			lines.add('Errors:');
			for(String error : this.runErrors){
				lines.add('- ' + error);
			}
		}
		if(!this.errorSamples.isEmpty()){
			lines.add('');
			lines.add('Deletion errors (up to ' + MAX_ERROR_SAMPLES + ' distinct messages):');
			for(String error : this.errorSamples){
				lines.add('- ' + error);
			}
		}
		lines.add('');
		lines.add('Configuration:');
		lines.add('- SObject: ' + this.sobjectName);
		lines.add('- Sequence: ' + this.sequence);
		lines.add('- WHERE clause: ' + getWhereClause());
		lines.add('- Batch size: ' + getBatchSize());
		lines.add('- Dry run: ' + this.dryRun);

		//the email template can be customized in the Email Templates tab; the lines above are used without it
		return new PurgeSObjectEmail(SUMMARY_EMAIL_TEMPLATE)
			.put('Status', isCoreDryRun ? (hasErrors ? 'dry run completed with errors' : 'dry run') : 'completed with errors')
			.put('ObjectName', this.sobjectName)
			.put('Sequence', this.sequence)
			.put('MatchedCount', isCoreDryRun ? this.matchedCount : this.deletedCount + this.failedCount)
			.put('DeletedCount', this.deletedCount)
			.put('FailedCount', this.failedCount)
			.put('FailedChunks', failedChunks)
			.put('FirstChunkError', failedChunks > 0 ? '(first error: ' + firstChunkError + ')' : '')
			.put('Errors', this.runErrors)
			.put('DeletionErrors', this.errorSamples)
			.put('WhereClause', getWhereClause())
			.put('BatchSize', getBatchSize())
			.put('DryRun', this.dryRun)
			.build(subject, String.join(lines, '\n'));
	}

	/**
	 * @description Publish platform events if enabled from the CMDT configuration: one event per record,
	 * or one event per chunk and result (success or failure) with the records in Records__c
	 * @param drList List<Database.DeleteResult>
	 * @param scope List<SObject>
	 * @return `List<PurgeSObjectBatch__e>` Platform events published
	 */
	@TestVisible
	private List<PurgeSObjectBatch__e> publishPlatformEventIfEnabled(List<Database.DeleteResult> drList, List<SObject> scope){

		List<PurgeSObjectBatch__e> peList = new List<PurgeSObjectBatch__e>();
		Map<Boolean, List<String>> chunkRecords = new Map<Boolean, List<String>>{true => new List<String>(), false => new List<String>()};

		//delete results are in the same order as the scope: use the index since getId() is empty when the deletion failed
		for(Integer i = 0; i < drList.size(); i++){
			Database.DeleteResult dr = drList.get(i);
			if((dr.isSuccess() && this.publishPeOk) || (!dr.isSuccess() && this.publishPeKo)){
				SObject rec = scope.get(i);
				String extId = getRecordExternalId(rec);
				String message = getError(dr.getErrors());

				if(this.publishPePerChunk){
					Map<String, Object> record = new Map<String, Object>{'id' => rec.Id};
					if(String.isNotBlank(extId)){
						record.put('externalId', extId);
					}
					if(String.isNotBlank(message)){
						record.put('message', message);
					}
					chunkRecords.get(dr.isSuccess()).add(JSON.serialize(record));
				} else{
					peList.add(new PurgeSObjectBatch__e(Id__c = rec.Id, Success__c = dr.isSuccess(),
					ExternalId__c = extId, SObject__c = this.sobjectName, Message__c = message));
				}
			}
		}
		for(Boolean success : chunkRecords.keySet()){
			peList.addAll(buildChunkEvents(success, chunkRecords.get(success)));
		}

		for (Database.SaveResult sr : EventBus.publish(peList)) {
			if (!sr.isSuccess()) {
				System.debug(LoggingLevel.ERROR, 'Error : ' + getError(sr.getErrors()));
			}
		}
		return peList;
	}

	/**
	 * @description Group the records in as few platform events as possible, without exceeding the Records__c field length
	 * @param success Indicates if the records were deleted
	 * @param records Records serialized in JSON
	 * @return `List<PurgeSObjectBatch__e>` Platform events to publish
	 */
	private List<PurgeSObjectBatch__e> buildChunkEvents(Boolean success, List<String> records){
		List<PurgeSObjectBatch__e> peList = new List<PurgeSObjectBatch__e>();
		List<String> eventRecords = new List<String>();
		//2 characters for the brackets of the JSON array, and 1 for the comma after each record
		Integer eventLength = 2;
		for(String rec : records){
			if(!eventRecords.isEmpty() && eventLength + rec.length() + 1 > recordsMaxLength){
				peList.add(newChunkEvent(success, eventRecords));
				eventRecords = new List<String>();
				eventLength = 2;
			}
			eventRecords.add(rec);
			eventLength += rec.length() + 1;
		}
		if(!eventRecords.isEmpty()){
			peList.add(newChunkEvent(success, eventRecords));
		}
		return peList;
	}

	/**
	 * @description Create a platform event for a group of records published per chunk
	 * @param success Indicates if the records were deleted
	 * @param records Records serialized in JSON
	 * @return `PurgeSObjectBatch__e` Platform event with the records in Records__c
	 */
	private PurgeSObjectBatch__e newChunkEvent(Boolean success, List<String> records){
		return new PurgeSObjectBatch__e(Success__c = success, SObject__c = this.sobjectName,
		Records__c = '[' + String.join(records, ',') + ']');
	}

	/**
	 * @description Log the error and publish a platform event if enabled, when the SObject configuration can't be processed
	 * @param message Error message
	 */
	private void publishConfigurationError(String message){
		System.debug(LoggingLevel.ERROR, 'Error : ' + this.sobjectName + ' - ' + message);
		if(this.publishPeKo){
			Database.SaveResult sr = EventBus.publish(new PurgeSObjectBatch__e(Success__c = false,
			SObject__c = this.sobjectName, Message__c = message));
			if(!sr.isSuccess()){
				System.debug(LoggingLevel.ERROR, 'Error : ' + getError(sr.getErrors()));
			}
		}
	}

	/**
	 * @description Returns a QueryLocator without any record, used when there is nothing to purge
	 * @return `Database.QueryLocator` QueryLocator without any record
	 */
	private Database.QueryLocator getEmptyQueryLocator(){
		return Database.getQueryLocator([SELECT Id FROM User WHERE Id = null]);
	}

	/**
	 * @description Returns the externalId field from the CMDT if not empty
	 * @return ExternalId field if not empty and platform event publication is checked
	 */
	private String getExternalIdValue(){
		String ext = '';
		if((this.publishPeOk || this.publishPeKo) && String.isNotBlank(this.externalId)){
			ext = ', ' + this.externalId;
		}
		return ext;
	}

	/**
	 * @description Returns the external id value of the record
	 * @param rec Record deleted
	 * @return `String` External id value, empty if the field is not set in the CMDT or has no value
	 */
	private String getRecordExternalId(SObject rec){
		Object value = String.isNotEmpty(this.externalId) ? rec.get(this.externalId) : null;
		return value != null ? String.valueOf(value) : '';
	}

	/**
	 * @description Returns the Database.Error list formatted as a String, one error per line
	 * @param errors
	 * @return  `String` Database.Error information (statusCode, fields and message)
	 */
	private String getError(List<Database.Error> errors){
		List<String> messages = new List<String>();
		for (Database.Error er: errors) {
			messages.add('[' + er.getStatusCode() + '] ' + er.getFields() + ' ' + er.getMessage());
		}
		return String.join(messages, '\n');
	}

	/**
	 * @description Allow user to define another field to be considered for deletion rules
	 * @return  `String` externalToBeDeleted if not blank, ToBeDeleted__c otherwise
	 */
	private String getToBeDeletedField(){
		return String.isNotBlank(this.externalToBeDeleted) ? this.externalToBeDeleted : 'ToBeDeleted__c';
	}

	/**
	 * @description Build the where clause based on different options (ToBeDeleted__c, ExternalToBeDeletedField__c or WhereClauseToBeDeleted__c)
	 * @return  `String` Where clause for the query
	 */
	private String getWhereClause(){
		if(String.isNotBlank(this.whereClause)){
			return this.whereClause;
		} else{
			return getToBeDeletedField() + '=true';
		}
	}
}
