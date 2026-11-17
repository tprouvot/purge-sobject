@isTest
private class PurgeDataLakeObjectJob_Test {

	private static PurgeDataLakeObjectMock setUp(){
		//the content of the built-in email is checked, even when the email template is deployed
		PurgeSObjectEmail.useTemplates = false;
		PurgeDataLakeObjectJob.captureInTests = true;
		PurgeDataLakeObjectMock mock = PurgeDataLakeObjectMock.withDefaults();
		Test.setMock(HttpCalloutMock.class, mock);
		return mock;
	}

	private static PurgeDataLakeObjectRun runStep(PurgeDataLakeObjectRun run, PurgeDataLakeObjectJob.JobStep step){
		new PurgeDataLakeObjectJob(run, step).execute((QueueableContext) null);
		return run;
	}

	@isTest
	static void dryRunCountsTheRecordsTest(){
		PurgeDataLakeObjectMock mock = setUp();
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'3'});
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.dryRun = true;

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.START);
		Test.stopTest();

		Assert.areEqual(3, run.matched, 'The matching records should be counted');
		Assert.isTrue(run.finished, 'A dry run should end after the count');
		Assert.isTrue(mock.getRequests('POST', '/api/v1/ingest/jobs').isEmpty(), 'A dry run should not create a job');
		Assert.areEqual(new List<Integer>{7}, PurgeDataLakeObjectJob.continuedAfter, 'The scheduled purge should continue');
		Assert.areEqual(1, PurgeDataLakeObjectReport.sentEmails.size(), 'A dry run should be reported by email');
		Assert.areEqual('Dry run of the purge of Orders__dll completed', PurgeDataLakeObjectReport.sentEmails.get(0).getSubject(),
			'The subject should name the dry run');
		Assert.isTrue(PurgeDataLakeObjectReport.sentEmails.get(0).getPlainTextBody().contains('Records matching the WHERE clause: 3'),
			'The email should contain the count');
	}

	@isTest
	static void startCreatesTheDeleteJobTest(){
		PurgeDataLakeObjectMock mock = setUp();
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'3'});
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.START);
		Test.stopTest();

		Assert.isTrue(run.errors.isEmpty(), 'The configuration should be valid: ' + run.errors);
		Assert.areEqual(PurgeDataLakeObjectMock.JOB_ID, run.jobId, 'The job should be created');
		Assert.isNull(run.recordVersion, 'No record version is sent without a record modified field');
		Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(mock.getRequests('POST', '/api/v1/ingest/jobs').get(0).getBody());
		Assert.areEqual('delete', body.get('operation'), 'The job should delete records');
		Assert.areEqual(PurgeDataLakeObjectMock.CONNECTOR, body.get('sourceName'), 'The short name of the connector should be used');
		Assert.areEqual(PurgeDataLakeObjectJob.JobStep.QUERY_PAGE, PurgeDataLakeObjectJob.enqueued.get(0).step, 'The query should start');
		Assert.isTrue(PurgeDataLakeObjectJob.continuedAfter.isEmpty(), 'The scheduled purge should wait until the job is closed');
	}

	@isTest
	static void recordModifiedFieldAddsTheRecordVersionTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('GET', '/ssot/data-lake-objects/', 200, PurgeDataLakeObjectMock.getDataLakeObject('lastModifiedDate__c'));
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'3'});
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		//the field name is accepted without the __c suffix
		run.primaryKeyField = 'order_id';

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.START);
		Test.stopTest();

		Assert.areEqual('lastModifiedDate__c', run.recordModifiedField, 'The record modified field should be read from the metadata');
		Assert.isNotNull(run.recordVersion, 'The current time should be sent as record version');
		Assert.areEqual(PurgeDataLakeObjectMock.PRIMARY_KEY, run.primaryKeyField, 'The API name of the primary key should be used');
	}

	@isTest
	static void unknownDataLakeObjectTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('GET', '/ssot/data-lake-objects/', 404, '[{"errorCode":"NOT_FOUND","message":"Not found"}]');
		assertConfigurationError(PurgeDataLakeObjectMock.newQueryRun(), 'Orders__dll doesn\'t exist');
	}

	@isTest
	static void wrongPrimaryKeyTest(){
		setUp();
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.primaryKeyField = 'id__c';
		assertConfigurationError(run, 'The primary key of Orders__dll is order_id__c, not id__c');
	}

	@isTest
	static void wrongDataspaceTest(){
		setUp();
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.dataspace = 'europe';
		assertConfigurationError(run, 'isn\'t in the data space europe');
	}

	@isTest
	static void unknownConnectorTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('GET', '/ssot/connections', 200, '{"connections":[]}');
		assertConfigurationError(PurgeDataLakeObjectMock.newQueryRun(), 'Web and Mobile SDK');
	}

	@isTest
	static void dataLakeObjectNotFedByTheConnectorTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('GET', '/ssot/data-streams', 200,
			'{"dataStreams":[{"connectorInfo":{"connectorType":"IngestApi"},"dataLakeObjectInfo":{"name":"Other__dll"}}]}');
		assertConfigurationError(PurgeDataLakeObjectMock.newQueryRun(), 'isn\'t fed by a data stream of the Ingestion API connector Ecomm');
	}

	@isTest
	static void invalidWhereClauseTest(){
		setUp();
		//a count that can't be read makes the query fail
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'not a number'});
		assertConfigurationError(PurgeDataLakeObjectMock.newQueryRun(), 'The records to delete could not be counted');
	}

	@isTest
	static void unknownObjectOfTheConnectorTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('POST', '/api/v1/ingest/jobs', 404, '{"message":"The requested resource doesn\'t exist."}');
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'3'});
		assertConfigurationError(PurgeDataLakeObjectMock.newQueryRun(), 'has no object Orders');
	}

	@isTest
	static void jobOfAnotherProcessIsNotUsedTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('POST', '/api/v1/ingest/jobs', 201, PurgeDataLakeObjectMock.getJob('upsert', 'Open', Datetime.now().addHours(-1)));
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'3'});
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.START);
		Test.stopTest();

		Assert.isNull(run.jobId, 'The job of another process should not be used');
		Assert.areEqual(1, run.attempts, 'The step should be tried again later');
		Assert.areEqual(PurgeDataLakeObjectJob.JobStep.START, PurgeDataLakeObjectJob.enqueued.get(0).step, 'The same step should be enqueued');
		Assert.areEqual(1, PurgeDataLakeObjectJob.enqueueDelays.get(0), 'The first retry should wait 1 minute');
		Assert.isTrue(mock.getRequests('PATCH', '/api/v1/ingest/jobs/').isEmpty(), 'The job of another process should not be aborted');
	}

	@isTest
	static void retriesAreLimitedTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('POST', '/api/v1/ingest/jobs', 409, '{"message":"unable to update the job state"}');
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'3'});
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.attempts = 4;

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.START);
		Test.stopTest();

		Assert.isTrue(run.finished, 'The run should end when the retries are exhausted');
		Assert.isTrue(run.errors.get(0).contains('after 4 retries'), 'The error should mention the retries: ' + run.errors);
		Assert.isTrue(PurgeDataLakeObjectReport.sentEmails.get(0).getSubject().endsWith('completed with errors'), 'The error should be emailed');
	}

	@isTest
	static void queryPageUploadsAndClosesTheJobTest(){
		PurgeDataLakeObjectMock mock = setUp();
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'A-1', 'A-2', 'B,3', ''});
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.recordVersion = '2026-11-13T10:00:00.000Z';

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.QUERY_PAGE);
		Test.stopTest();

		List<HttpRequest> uploads = mock.getRequests('PUT', '/batches');
		Assert.areEqual(1, uploads.size(), 'The page should be uploaded as one file');
		Assert.areEqual('A-1,2026-11-13T10:00:00.000Z\nA-2,2026-11-13T10:00:00.000Z\n"B,3",2026-11-13T10:00:00.000Z\n',
			uploads.get(0).getBody(), 'The CSV should have no header, the escaped keys and the record version');
		Assert.areEqual(4, run.queried, 'All the rows should be counted as queried');
		Assert.areEqual(3, run.submitted, 'The empty key should not be submitted');
		Assert.isTrue(mock.getRequests('PATCH', '/api/v1/ingest/jobs/').get(0).getBody().contains('UploadComplete'), 'The job should be closed');
		Assert.areEqual(new List<Integer>{7}, PurgeDataLakeObjectJob.continuedAfter, 'The scheduled purge should continue once the job is closed');
		Assert.areEqual(PurgeDataLakeObjectJob.JobStep.POLL, PurgeDataLakeObjectJob.enqueued.get(0).step, 'The job should be polled');
		Assert.areEqual(3, PurgeDataLakeObjectJob.enqueueDelays.get(0), 'The first poll should wait 3 minutes');
	}

	@isTest
	static void largeBodyIsSplitTest(){
		PurgeDataLakeObjectMock mock = setUp();
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'A-1', 'A-2', 'A-3', 'A-4'});
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		PurgeDataLakeObjectJob.maxRequestBody = 10;

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.QUERY_PAGE);
		Test.stopTest();

		Assert.areEqual(2, mock.getRequests('PUT', '/batches').size(), 'A body larger than the limit should be split');
		Assert.areEqual(2, run.files, 'Each upload should count as a file');
		Assert.areEqual(4, run.submitted, 'All the keys should be submitted');
	}

	@isTest
	static void emptyPageAbortsTheJobTest(){
		PurgeDataLakeObjectMock mock = setUp();
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>());
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.QUERY_PAGE);
		Test.stopTest();

		Assert.isTrue(mock.getRequests('PATCH', '/api/v1/ingest/jobs/').get(0).getBody().contains('Aborted'), 'An empty job should be aborted');
		Assert.areEqual('Aborted', run.jobState, 'The job should be aborted');
		Assert.isTrue(run.finished, 'The run should end');
		Assert.isTrue(run.errors.isEmpty(), 'Nothing to delete is not an error');
	}

	@isTest
	static void pollUntilTheJobIsCompleteTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('GET', '/api/v1/ingest/jobs/', 200, '{"state":"InProgress"}')
			.respondTo('GET', '/api/v1/ingest/jobs/', 200, '{"state":"JobComplete","totalProcessingTime":319}');
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.closedAt = Datetime.now();

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.POLL);
		runStep(run, PurgeDataLakeObjectJob.JobStep.POLL);
		Test.stopTest();

		Assert.areEqual(PurgeDataLakeObjectJob.JobStep.POLL, PurgeDataLakeObjectJob.enqueued.get(0).step, 'A running job should be polled again');
		Assert.areEqual(5, PurgeDataLakeObjectJob.enqueueDelays.get(0), 'The next poll should wait 5 minutes');
		Assert.areEqual(PurgeDataLakeObjectJob.JobStep.CHECK, PurgeDataLakeObjectJob.enqueued.get(1).step, 'A complete job should be checked');
		Assert.areEqual(319, run.processingTime, 'The processing time should be kept');
	}

	@isTest
	static void failedJobIsReportedTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('GET', '/api/v1/ingest/jobs/', 200, '{"state":"Failed"}');
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.closedAt = Datetime.now();

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.POLL);
		Test.stopTest();

		Assert.isTrue(run.errors.get(0).contains('ended with the state Failed'), 'A failed job should be reported');
		Assert.isFalse(PurgeDataLakeObjectReport.publishedEvents.get(0).Success__c, 'A failure event should be published');
	}

	@isTest
	static void pollTimeoutIsAWarningTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('GET', '/api/v1/ingest/jobs/', 200, '{"state":"InProgress"}');
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.closedAt = Datetime.now().addHours(-3);

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.POLL);
		Test.stopTest();

		Assert.isTrue(run.finished, 'The run should end after the timeout');
		Assert.isTrue(run.warnings.get(0).contains('still InProgress'), 'The timeout should be a warning');
		Assert.isTrue(PurgeDataLakeObjectReport.sentEmails.get(0).getSubject().endsWith('completed with warnings'), 'The warning should be emailed');
	}

	@isTest
	static void checkWithoutRemainingRecordsTest(){
		setUp();
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'0'});
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.jobState = 'JobComplete';
		run.submitted = 3;

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.CHECK);
		Test.stopTest();

		Assert.areEqual(0, run.stillPresent, 'No record should be left');
		Assert.isTrue(run.isSuccess(), 'The run should succeed');
		Assert.isTrue(PurgeDataLakeObjectReport.sentEmails.isEmpty(), 'A successful run should not send an email');
		PurgeSObjectBatch__e event = PurgeDataLakeObjectReport.publishedEvents.get(0);
		Assert.isTrue(event.Success__c, 'A success event should be published');
		Assert.areEqual(PurgeDataLakeObjectMock.JOB_ID, event.ExternalId__c, 'The event should contain the job id');
		Assert.areEqual(3, ((Map<String, Object>) JSON.deserializeUntyped(event.Records__c)).get('submitted'), 'The event should contain the counts');
	}

	@isTest
	static void checkWithRemainingRecordsTest(){
		setUp();
		PurgeDataLakeObjectMock.mockQueryValues(new List<String>{'2'});
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.jobState = 'JobComplete';

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.CHECK);
		Test.stopTest();

		Assert.areEqual(2, run.stillPresent, 'The remaining records should be counted');
		Assert.isFalse(run.isSuccess(), 'Remaining records are an error');
		Assert.isTrue(PurgeDataLakeObjectReport.sentEmails.get(0).getPlainTextBody()
			.contains('Records still matching the WHERE clause after the job (not deleted): 2'), 'The remaining records should be emailed');
	}

	@isTest
	static void finalizerAbortsTheOpenJobTest(){
		PurgeDataLakeObjectMock mock = setUp();
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.jobState = 'Open';
		PurgeDataLakeObjectJob job = new PurgeDataLakeObjectJob(run, PurgeDataLakeObjectJob.JobStep.QUERY_PAGE);

		Test.startTest();
		job.execute(new FailedContext());
		Test.stopTest();

		Assert.isTrue(mock.getRequests('PATCH', '/api/v1/ingest/jobs/').get(0).getBody().contains('Aborted'), 'The open job should be aborted');
		Assert.isTrue(run.errors.get(0).contains('Unhandled error in the QUERY_PAGE step: Apex heap size too large'), 'The error should be reported');
		Assert.areEqual(new List<Integer>{7}, PurgeDataLakeObjectJob.continuedAfter, 'The scheduled purge should continue');
	}

	@isTest
	static void finalizerReportsAStepWithoutNextStepTest(){
		setUp();
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		PurgeDataLakeObjectJob job = new PurgeDataLakeObjectJob(run, PurgeDataLakeObjectJob.JobStep.POLL);

		Test.startTest();
		job.execute(new FailedContext(ParentJobResult.SUCCESS));
		Test.stopTest();

		Assert.isTrue(run.errors.get(0).contains('ended without starting the next step'), 'A stopped run should be reported: ' + run.errors);
		Assert.isTrue(run.finished, 'The run should end');
	}

	@isTest
	static void tokenErrorTest(){
		PurgeDataLakeObjectMock mock = setUp();
		mock.replace('POST', '/services/a360/token', 400, '{"error":"invalid_scope","error_description":"the requested scope is not allowed"}');
		PurgeDataLakeObjectRun run = PurgeDataLakeObjectMock.newQueryRun();
		run.jobId = PurgeDataLakeObjectMock.JOB_ID;
		run.closedAt = Datetime.now();

		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.POLL);
		Test.stopTest();

		Assert.isTrue(run.errors.get(0).contains('the requested scope is not allowed'), 'The error of the token exchange should be reported');
		Assert.isTrue(run.errors.get(0).contains('CDPIngest'), 'The error should explain what to check');
	}

	@isTest
	static void templateHasNoUnknownPlaceholderTest(){
		if([SELECT COUNT() FROM EmailTemplate WHERE DeveloperName = 'PurgeDataLakeObject_Summary'] == 0){
			//the template isn't deployed: the built-in email is used
			return;
		}
		PurgeDataLakeObjectRun queryRun = PurgeDataLakeObjectMock.newQueryRun();
		queryRun.errors.add('An <error>');
		PurgeDataLakeObjectRun fileRun = PurgeDataLakeObjectMock.newQueryRun();
		fileRun.mode = PurgeDataLakeObjectRun.RunMode.FILES;
		fileRun.contentDocumentIds = new List<Id>{'069000000000000AAA'};
		fileRun.warnings.add('A warning');

		for(PurgeDataLakeObjectRun run : new List<PurgeDataLakeObjectRun>{queryRun, fileRun}){
			Messaging.SingleEmailMessage email = PurgeDataLakeObjectReport.buildEmail(run, 'Built-in body');
			Assert.isFalse(email.getSubject().contains('{{'), 'Every placeholder of the subject should be known: ' + email.getSubject());
			Assert.isFalse(email.getHtmlBody().contains('{{'), 'Every placeholder of the body should be known: ' + email.getHtmlBody());
		}
		Assert.isTrue(PurgeDataLakeObjectReport.buildEmail(queryRun, '').getHtmlBody().contains('An &lt;error&gt;'),
			'The errors should be escaped in the email');
	}

	@isTest
	static void helpersTest(){
		Assert.areEqual('Ecomm', PurgeDataLakeObjectJob.getSourceName(PurgeDataLakeObjectMock.CONNECTION_NAME), 'The generated suffix should be removed');
		Assert.areEqual('Ecomm', PurgeDataLakeObjectJob.getSourceName('Ecomm'), 'A name without suffix should be kept');
		Assert.isTrue(PurgeDataLakeObjectJob.isSameField('order_id__c', ' Order_Id '), 'The __c suffix and the case should be ignored');
		Assert.isFalse(PurgeDataLakeObjectJob.isSameField('order_id__c', null), 'An empty field name never matches');
		Assert.areEqual('"a ""b"",c"', PurgeDataLakeObjectJob.escapeCsv('a "b",c'), 'Quotes and commas should be escaped');
		Assert.areEqual('abc', PurgeDataLakeObjectJob.escapeCsv('abc'), 'A simple key should not be quoted');
	}

	@isTest
	static void invalidParametersTest(){
		PurgeDataLakeObjectRun run = new PurgeDataLakeObjectRun();
		run.mode = PurgeDataLakeObjectRun.RunMode.QUERY;
		run.dataLakeObject = 'Orders__dlm';
		run.chunkSize = 10;
		try {
			run.validateParameters();
			Assert.fail('Invalid parameters should be rejected');
		} catch (PurgeDataLakeObjectRun.ConfigurationException e) {
			for(String expected : new List<String>{'must end with __dll', 'IngestionConnector__c', 'IngestionObject__c',
				'PrimaryKeyField__c', 'WhereClauseToBeDeleted__c', 'chunk size'}){
				Assert.isTrue(e.getMessage().contains(expected), 'The error should mention ' + expected + ': ' + e.getMessage());
			}
		}
	}

	private static void assertConfigurationError(PurgeDataLakeObjectRun run, String expected){
		Test.startTest();
		runStep(run, PurgeDataLakeObjectJob.JobStep.START);
		Test.stopTest();

		Assert.isTrue(run.finished, 'An invalid configuration should end the run');
		Assert.isTrue(!run.errors.isEmpty() && run.errors.get(0).contains(expected), 'The error should contain "' + expected + '": ' + run.errors);
		Assert.isNull(run.jobId, 'No job should be created');
		Assert.areEqual(new List<Integer>{7}, PurgeDataLakeObjectJob.continuedAfter, 'The scheduled purge should continue');
		Assert.isFalse(PurgeDataLakeObjectReport.publishedEvents.get(0).Success__c, 'A failure event should be published');
	}

	/**
	 * @description Context of a job that failed with an error that Apex can't catch
	 */
	private class FailedContext implements FinalizerContext {
		private ParentJobResult result = ParentJobResult.UNHANDLED_EXCEPTION;
		public FailedContext(){
			return;
		}
		public FailedContext(ParentJobResult result){
			this.result = result;
		}
		public Id getAsyncApexJobId(){
			return null;
		}
		public Exception getException(){
			return this.result == ParentJobResult.UNHANDLED_EXCEPTION ? new LimitException('Apex heap size too large') : null;
		}
		public String getRequestId(){
			return null;
		}
		public ParentJobResult getResult(){
			return this.result;
		}
	}

	private class LimitException extends Exception {}
}
