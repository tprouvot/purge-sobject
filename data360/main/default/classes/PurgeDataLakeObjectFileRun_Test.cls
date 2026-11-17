@isTest
private class PurgeDataLakeObjectFileRun_Test {

	@TestSetup
	static void makeData(){
		insert new List<ContentVersion>{
			new ContentVersion(Title = 'keys', PathOnClient = 'keys.csv',
				VersionData = Blob.valueOf(PurgeDataLakeObjectMock.PRIMARY_KEY + '\r\nK-1\r\n"K-2"\r\n\r\nK-3\r\n')),
			new ContentVersion(Title = 'wrong header', PathOnClient = 'wrong.csv', VersionData = Blob.valueOf('id\nK-1\n'))
		};
	}

	private static Id getFile(String title){
		return [SELECT ContentDocumentId FROM ContentVersion WHERE Title = :title AND IsLatest = true].ContentDocumentId;
	}

	private static PurgeDataLakeObjectMock setUp(){
		//the content of the built-in email is checked, even when the email template is deployed
		PurgeSObjectEmail.useTemplates = false;
		PurgeDataLakeObjectJob.captureInTests = true;
		PurgeDataLakeObjectMock mock = PurgeDataLakeObjectMock.withDefaults();
		Test.setMock(HttpCalloutMock.class, mock);
		return mock;
	}

	private static PurgeDataLakeObjectFileRun newFileRun(String title){
		PurgeDataLakeObjectFileRun fileRun = new PurgeDataLakeObjectFileRun();
		fileRun.dataLakeObject = PurgeDataLakeObjectMock.DATA_LAKE_OBJECT;
		fileRun.connector = PurgeDataLakeObjectMock.CONNECTOR;
		fileRun.sourceObject = PurgeDataLakeObjectMock.SOURCE_OBJECT;
		fileRun.primaryKeyField = PurgeDataLakeObjectMock.PRIMARY_KEY;
		fileRun.contentDocumentIds = new List<Id>{getFile(title)};
		return fileRun;
	}

	private static PurgeDataLakeObjectRun newRun(String title, Boolean dryRun){
		PurgeDataLakeObjectRun run = new PurgeDataLakeObjectRun();
		run.mode = PurgeDataLakeObjectRun.RunMode.FILES;
		run.dataLakeObject = PurgeDataLakeObjectMock.DATA_LAKE_OBJECT;
		run.connector = PurgeDataLakeObjectMock.CONNECTOR;
		run.sourceObject = PurgeDataLakeObjectMock.SOURCE_OBJECT;
		run.primaryKeyField = PurgeDataLakeObjectMock.PRIMARY_KEY;
		run.contentDocumentIds = new List<Id>{getFile(title)};
		run.dryRun = dryRun;
		run.validateParameters();
		return run;
	}

	private static void runStep(PurgeDataLakeObjectRun run, PurgeDataLakeObjectJob.JobStep step){
		new PurgeDataLakeObjectJob(run, step).execute((QueueableContext) null);
	}

	@isTest
	static void fileRunIsADryRunByDefaultTest(){
		setUp();
		PurgeDataLakeObjectFileRun fileRun = newFileRun('keys');

		Test.startTest();
		fileRun.start();
		Test.stopTest();

		PurgeDataLakeObjectJob job = PurgeDataLakeObjectJob.enqueued.get(0);
		Assert.areEqual(PurgeDataLakeObjectJob.JobStep.START, job.step, 'The run should start with the validation');
		Assert.isTrue(job.run.dryRun, 'A file run should be a dry run unless dryRun is false');
		Assert.areEqual(PurgeDataLakeObjectRun.RunMode.FILES, job.run.mode, 'The run should read the files');
		Assert.isNull(job.run.sequence, 'A file run is not part of the scheduled purge');
	}

	@isTest
	static void fileRunRejectsUnknownFilesTest(){
		setUp();
		PurgeDataLakeObjectFileRun fileRun = newFileRun('keys');
		fileRun.contentDocumentIds = new List<Id>{'069000000000000AAA'};
		try {
			fileRun.start();
			Assert.fail('An unknown file should be rejected');
		} catch (PurgeDataLakeObjectRun.ConfigurationException e) {
			Assert.isTrue(e.getMessage().contains('doesn\'t exist or isn\'t shared with you'), 'The error should name the file: ' + e.getMessage());
		}
	}

	@isTest
	static void fileRunRejectsLargeFilesTest(){
		setUp();
		PurgeDataLakeObjectJob.maxFileSize = 5;
		try {
			newFileRun('keys').start();
			Assert.fail('A large file should be rejected');
		} catch (PurgeDataLakeObjectRun.ConfigurationException e) {
			Assert.isTrue(e.getMessage().contains('"keys" is larger than'), 'The error should name the file: ' + e.getMessage());
		}
	}

	@isTest
	static void fileDryRunCountsTheKeysTest(){
		PurgeDataLakeObjectMock mock = setUp();
		PurgeDataLakeObjectRun run = newRun('keys', true);

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.START);
		runStep(run, PurgeDataLakeObjectJob.JobStep.UPLOAD_FILE);
		Test.stopTest();

		Assert.areEqual(3, run.queried, 'The keys of the file should be counted, without the header and the empty lines');
		Assert.isTrue(mock.getRequests('POST', '/api/v1/ingest/jobs').isEmpty(), 'A dry run should not create a job');
		Assert.isTrue(mock.getRequests('PUT', '/batches').isEmpty(), 'A dry run should not upload anything');
		Assert.isTrue(PurgeDataLakeObjectReport.sentEmails.get(0).getPlainTextBody().contains('Primary keys in the files: 3'),
			'The count should be emailed');
		Assert.isTrue(PurgeDataLakeObjectJob.continuedAfter.isEmpty(), 'A file run doesn\'t continue the scheduled purge');
	}

	@isTest
	static void fileIsUploadedTest(){
		PurgeDataLakeObjectMock mock = setUp();
		PurgeDataLakeObjectRun run = newRun('keys', false);
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.jobState = 'Open';

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.UPLOAD_FILE);
		Test.stopTest();

		Assert.areEqual('K-1\nK-2\nK-3\n', mock.getRequests('PUT', '/batches').get(0).getBody(), 'The keys should be sent without header');
		Assert.areEqual(3, run.submitted, 'The keys should be submitted');
		Assert.isTrue(mock.getRequests('PATCH', '/api/v1/ingest/jobs/').get(0).getBody().contains('UploadComplete'), 'The job should be closed');
		Assert.areEqual(PurgeDataLakeObjectJob.JobStep.POLL, PurgeDataLakeObjectJob.enqueued.get(0).step, 'The job should be polled');
	}

	@isTest
	static void wrongHeaderIsRejectedTest(){
		PurgeDataLakeObjectMock mock = setUp();
		PurgeDataLakeObjectRun run = newRun('wrong header', false);
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.jobState = 'Open';

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.UPLOAD_FILE);
		Test.stopTest();

		Assert.isTrue(run.errors.get(0).contains('must be the primary key field order_id__c'), 'The header should be checked: ' + run.errors);
		Assert.isTrue(mock.getRequests('PUT', '/batches').isEmpty(), 'Nothing should be uploaded');
		Assert.isTrue(mock.getRequests('PATCH', '/api/v1/ingest/jobs/').get(0).getBody().contains('Aborted'), 'The open job should be aborted');
	}

	@isTest
	static void checkCountsTheRemainingKeysTest(){
		setUp();
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'1'});
		PurgeDataLakeObjectRun run = newRun('keys', false);
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.jobState = 'JobComplete';
		run.submitted = 3;

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.CHECK);
		Test.stopTest();

		Assert.areEqual(3, run.checked, 'All the keys should be checked');
		Assert.areEqual(1, run.stillPresent, 'The remaining keys should be counted');
		Assert.isTrue(PurgeDataLakeObjectReport.sentEmails.get(0).getPlainTextBody()
			.contains('Primary keys still present after the job (not deleted): 1 of 3 checked'), 'The remaining keys should be emailed');
	}

	@isTest
	static void filesAreRenamedAfterThePurgeTest(){
		setUp();
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'0'});
		PurgeDataLakeObjectRun run = newRun('keys', false);
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.jobState = 'JobComplete';
		run.submitted = 3;

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.CHECK);
		Test.stopTest();

		String title = [SELECT Title FROM ContentVersion WHERE ContentDocumentId = :run.contentDocumentIds.get(0) AND IsLatest = true].Title;
		Assert.isTrue(title.startsWith('keys [purged '), 'The file should be marked as purged: ' + title);
		Assert.isTrue(title.endsWith('job ' + PurgeDataLakeObjectMock.JOB_ID + ']'), 'The title should contain the job id: ' + title);
		Assert.isTrue(PurgeDataLakeObjectReport.publishedEvents.isEmpty(), 'A file run doesn\'t publish platform events');
	}

	@isTest
	static void handlerTest(){
		PurgeDataLakeObjectJob.captureInTests = true;
		PurgeDataLakeObjectHandler handler = new PurgeDataLakeObjectHandler();
		PurgeSObjectSetting__mdt setting = new PurgeSObjectSetting__mdt(DeveloperName = 'Orders', MasterLabel = 'Orders',
			SObjectApiName__c = 'Orders__dll', Sequence__c = 7, IngestionConnector__c = PurgeDataLakeObjectMock.CONNECTOR,
			IngestionObject__c = PurgeDataLakeObjectMock.SOURCE_OBJECT, PrimaryKeyField__c = PurgeDataLakeObjectMock.PRIMARY_KEY,
			WhereClauseToBeDeleted__c = '"label__c" = \'old\'', ChunkSize__c = 20000, DryRun__c = true,
			PublishPlatformEventOk__c = true, PublishPlatformEventKo__c = false);

		Assert.isTrue(handler.handles(setting), 'A Data Lake Object should be handled');
		Assert.isTrue(handler.handles(new PurgeSObjectSetting__mdt(SObjectApiName__c = 'ssot__Individual__dlm')), 'A Data Model Object should be handled');
		Assert.isFalse(handler.handles(new PurgeSObjectSetting__mdt(SObjectApiName__c = 'Account')), 'An SObject should not be handled');
		Assert.isFalse(handler.isRunning(), 'No purge should be running');

		handler.start(setting);
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectJob.enqueued.get(0).run;
		Assert.areEqual(7, run.sequence, 'The sequence should be kept to continue the scheduled purge');
		Assert.areEqual(20000, run.chunkSize, 'The chunk size of the setting should be used');
		Assert.areEqual('default', run.dataspace, 'The default data space should be used');
		Assert.isTrue(run.dryRun && run.publishPeOk && !run.publishPeKo, 'The options of the setting should be used');

		try {
			handler.start(new PurgeSObjectSetting__mdt(SObjectApiName__c = 'ssot__Individual__dlm'));
			Assert.fail('A Data Model Object should be rejected');
		} catch (PurgeDataLakeObjectRun.ConfigurationException e) {
			Assert.isTrue(e.getMessage().contains('Data Lake Object (__dll)'), 'The error should explain where to delete: ' + e.getMessage());
		}
	}
}
