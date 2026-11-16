/**
 * @description Report of the purge of a Data Lake Object: debug log, summary email to the running user
 * (when there are errors or warnings, and for a dry run), PurgeSObjectBatch__e platform event, and the renaming of the files
 * of a one-time file run
 */
public with sharing class PurgeDataLakeObjectReport {

	private static final Integer MAX_TITLE_LENGTH = 255;
	//Lightning email template of the summary email, customizable in the Email Templates tab
	private static final String SUMMARY_EMAIL_TEMPLATE = 'PurgeDataLakeObject_Summary';

	@TestVisible
	private static List<PurgeSObjectBatch__e> publishedEvents = new List<PurgeSObjectBatch__e>();
	@TestVisible
	private static List<Messaging.SingleEmailMessage> sentEmails = new List<Messaging.SingleEmailMessage>();

	/**
	 * @description Report the end of the run
	 * @param run State of the run
	 */
	public static void send(PurgeDataLakeObjectRun run){
		String body = getBody(run);
		System.debug(run.isSuccess() ? LoggingLevel.INFO : LoggingLevel.ERROR, body);

		//the files are renamed first: a failure is then added to the email
		renameFiles(run);
		publishEvent(run);
		if(!run.isSuccess() || run.dryRun || !run.warnings.isEmpty()){
			sendEmail(run, getBody(run));
		}
	}

	/**
	 * @description Returns the subject of the summary email
	 * @param run State of the run
	 * @return `String` Subject
	 */
	@TestVisible
	private static String getSubject(PurgeDataLakeObjectRun run){
		String prefix = (run.dryRun ? 'Dry run of the purge of ' : 'Purge of ') + run.dataLakeObject;
		if(!run.isSuccess()){
			return prefix + ' completed with errors';
		}
		return prefix + (run.warnings.isEmpty() ? ' completed' : ' completed with warnings');
	}

	/**
	 * @description Returns the text of the summary
	 * @param run State of the run
	 * @return `String` Summary
	 */
	@TestVisible
	private static String getBody(PurgeDataLakeObjectRun run){
		Boolean queryMode = run.mode == PurgeDataLakeObjectRun.RunMode.QUERY;
		List<String> lines = new List<String>{getSubject(run) + '.', ''};
		if(run.dryRun){
			lines.add('No record was deleted.');
			lines.add(queryMode
				? 'Records matching the WHERE clause: ' + valueOf(run.matched)
				: 'Primary keys in the files: ' + run.queried);
		} else{
			if(queryMode){
				lines.add('Records matching the WHERE clause at the start: ' + valueOf(run.matched));
				lines.add('Primary keys queried: ' + run.queried);
			} else{
				lines.add('Primary keys read in the files: ' + run.queried);
			}
			lines.add('Primary keys submitted for deletion: ' + run.submitted + ' in ' + run.files + ' file(s)');
			lines.add('Ingestion API job: ' + valueOf(run.jobId) + ', state ' + valueOf(run.jobState)
				+ (run.processingTime != null ? ' (processing time: ' + run.processingTime + ' s)' : ''));
			if(run.stillPresent != null){
				lines.add(queryMode
					? 'Records still matching the WHERE clause after the job (not deleted): ' + run.stillPresent
					: 'Primary keys still present after the job (not deleted): ' + run.stillPresent + ' of ' + run.checked + ' checked'
						+ (run.checked < run.submitted ? ' (sample)' : ''));
			}
		}
		addSection(lines, 'Errors:', run.errors);
		addSection(lines, 'Warnings:', run.warnings);
		lines.add('');
		lines.add('Configuration:');
		lines.add('- Mode: ' + (queryMode ? 'scheduled query (setting ' + run.settingName + ', sequence ' + run.sequence + ')' : 'one-time file run'));
		lines.add('- Data Lake Object: ' + run.dataLakeObject + ' (data space ' + run.dataspace + ')');
		lines.add('- Ingestion API connector and object: ' + run.connector + ' / ' + run.sourceObject);
		lines.add('- Primary key: ' + run.primaryKeyField);
		if(queryMode){
			lines.add('- WHERE clause: ' + run.whereClause);
		} else{
			lines.add('- Files: ' + String.join(run.contentDocumentIds, ', '));
		}
		lines.add('- Chunk size: ' + run.chunkSize);
		lines.add('- Record version column: ' + (String.isNotBlank(run.recordModifiedField) ? 'yes (' + run.recordModifiedField + ')' : 'no'));
		lines.add('- Dry run: ' + run.dryRun);
		if(!run.dryRun && run.jobId != null){
			lines.add('');
			lines.add('The records are deleted from the Data Lake Object. The Data Model Objects, identity resolution, segments '
				+ 'and calculated insights are updated at their next run.');
		}
		return String.join(lines, '\n');
	}

	private static void addSection(List<String> lines, String title, List<String> messages){
		if(messages.isEmpty()){
			return;
		}
		lines.add('');
		lines.add(title);
		for(String message : messages){
			lines.add('- ' + message);
		}
	}

	private static String valueOf(Object value){
		return value == null ? '-' : String.valueOf(value);
	}

	/**
	 * @description Publish one PurgeSObjectBatch__e for the job of a scheduled run, when the setting enables it
	 * @param run State of the run
	 */
	private static void publishEvent(PurgeDataLakeObjectRun run){
		Boolean success = run.isSuccess();
		if(run.mode != PurgeDataLakeObjectRun.RunMode.QUERY || run.dryRun
			|| !((success && run.publishPeOk && run.jobId != null) || (!success && run.publishPeKo))){
			return;
		}
		Map<String, Object> counts = new Map<String, Object>{
			'matched' => run.matched, 'queried' => run.queried, 'submitted' => run.submitted, 'files' => run.files,
			'state' => run.jobState, 'processingTime' => run.processingTime, 'stillMatching' => run.stillPresent};
		PurgeSObjectBatch__e event = new PurgeSObjectBatch__e(Success__c = success, SObject__c = run.dataLakeObject,
			ExternalId__c = run.jobId, Records__c = JSON.serialize(counts),
			Message__c = run.errors.isEmpty() ? null : String.join(run.errors, '\n'));
		publishedEvents.add(event);
		Database.SaveResult result = EventBus.publish(event);
		if(!result.isSuccess()){
			System.debug(LoggingLevel.ERROR, 'The platform event could not be published: ' + result.getErrors());
		}
	}

	/**
	 * @description Add the date and the job id to the title of the files of a completed file run,
	 * so that they aren't used again by mistake
	 * @param run State of the run
	 */
	private static void renameFiles(PurgeDataLakeObjectRun run){
		if(run.mode != PurgeDataLakeObjectRun.RunMode.FILES || run.dryRun || run.jobState != 'JobComplete'){
			return;
		}
		String suffix = ' [purged ' + Date.today().format() + ', job ' + run.jobId + ']';
		try {
			List<ContentVersion> versions = [SELECT Id, Title FROM ContentVersion
				WHERE ContentDocumentId IN :run.contentDocumentIds AND IsLatest = true];
			for(ContentVersion version : versions){
				version.Title = version.Title.left(MAX_TITLE_LENGTH - suffix.length()) + suffix;
			}
			update versions;
		} catch (Exception e) {
			run.warnings.add('The files could not be renamed: ' + e.getMessage());
		}
	}

	/**
	 * @description Returns the summary email, from the Lightning email template PurgeDataLakeObject_Summary when it is deployed
	 * and visible to the running user, or from the built-in text otherwise
	 * @param run State of the run
	 * @param body Built-in text of the summary
	 * @return `Messaging.SingleEmailMessage` Email
	 */
	@TestVisible
	private static Messaging.SingleEmailMessage buildEmail(PurgeDataLakeObjectRun run, String body){
		Boolean queryMode = run.mode == PurgeDataLakeObjectRun.RunMode.QUERY;
		String status;
		if(run.dryRun){
			status = run.isSuccess() ? 'dry run' : 'dry run completed with errors';
		} else{
			status = !run.isSuccess() ? 'completed with errors' : (run.warnings.isEmpty() ? 'completed' : 'completed with warnings');
		}
		return new PurgeSObjectEmail(SUMMARY_EMAIL_TEMPLATE)
			.put('Status', status)
			.put('ObjectName', run.dataLakeObject)
			.put('Mode', queryMode ? 'scheduled purge' : 'one-time file run')
			.put('SettingName', run.settingName)
			.put('Sequence', run.sequence)
			.put('MatchedCount', queryMode ? run.matched : run.queried)
			.put('QueriedCount', run.queried)
			.put('SubmittedCount', run.submitted)
			.put('FileCount', run.files)
			.put('JobId', run.jobId)
			.put('JobState', run.jobState)
			.put('ProcessingTime', run.processingTime)
			.put('NotDeletedCount', run.stillPresent)
			.put('CheckedCount', queryMode ? (Object) 'all' : (Object) run.checked)
			.put('Errors', run.errors)
			.put('Warnings', run.warnings)
			.put('Connector', run.connector)
			.put('SourceObject', run.sourceObject)
			.put('PrimaryKey', run.primaryKeyField)
			.put('Dataspace', run.dataspace)
			.put('WhereClause', queryMode ? run.whereClause : null)
			.put('Files', queryMode ? null : (Object) toStrings(run.contentDocumentIds))
			.put('ChunkSize', run.chunkSize)
			.put('RecordVersion', String.isNotBlank(run.recordModifiedField) ? 'Yes (' + run.recordModifiedField + ')' : 'No')
			.put('DryRun', run.dryRun)
			.build(getSubject(run), body);
	}

	private static List<String> toStrings(List<Id> ids){
		List<String> values = new List<String>();
		for(Id value : ids){
			values.add(value);
		}
		return values;
	}

	private static void sendEmail(PurgeDataLakeObjectRun run, String body){
		Messaging.SingleEmailMessage email = buildEmail(run, body);
		sentEmails.add(email);
		try {
			Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{email});
		} catch (Exception e) {
			//for example when the email deliverability of the org doesn't allow Apex emails
			System.debug(LoggingLevel.ERROR, 'The summary email could not be sent: ' + e.getMessage());
		}
	}
}
