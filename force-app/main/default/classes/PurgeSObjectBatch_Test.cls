@isTest
private class PurgeSObjectBatch_Test {
	//TODO This test class must be adapted to your implementation and SObjects to purge
	private static final String STRING_DELETE_CRITERIA = 'TO-BE-DELETED';

	@TestSetup
	static void makeData(){
		List<Lead> leadsList = new List<Lead>();
		Lead leadDelete = new Lead(
			FirstName = 'John',
			LastName = STRING_DELETE_CRITERIA
		);
		Lead leadNotDelete = new Lead(
			FirstName = 'John',
			LastName = 'Doe'
		);
		leadsList.add(leadDelete);
		leadsList.add(leadNotDelete);
		insert leadsList;
	}

	@isTest
	static void purgeSobjectTest(){
		Lead leadToBeDeleted = [SELECT Id, IsDeleted FROM Lead WHERE LastName =: STRING_DELETE_CRITERIA];

		Test.startTest();
		Database.executeBatch(new PurgeSObjectBatch());
		Test.stopTest();

		List<Lead> deletedLeads = [SELECT Id, IsDeleted FROM Lead WHERE IsDeleted=true ALL ROWS];
		Assert.areEqual(1, deletedLeads.size(), 'One lead should be deleted');
		Assert.areEqual(leadToBeDeleted.Id, deletedLeads.get(0).Id, 'We did not expect this lead to be deleted');
	}

	@isTest
	static void publishPlatformEventOnFailureTest(){
		Lead leadNotDeleted = [SELECT Id, LastName FROM Lead WHERE LastName =: STRING_DELETE_CRITERIA];

		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		batch.publishPeKo = true;
		batch.publishPePerChunk = false;
		batch.externalId = 'LastName';

		Test.startTest();
		List<PurgeSObjectBatch__e> events = batch.publishPlatformEventIfEnabled(
			new List<Database.DeleteResult>{getFailedDeleteResult()}, new List<SObject>{leadNotDeleted});
		Test.stopTest();

		Assert.areEqual(1, events.size(), 'One failure event should be published');
		PurgeSObjectBatch__e pe = events.get(0);
		Assert.areEqual(String.valueOf(leadNotDeleted.Id), pe.Id__c, 'Event should reference the record that failed to be deleted');
		Assert.areEqual(STRING_DELETE_CRITERIA, pe.ExternalId__c, 'Event should contain the record external id');
		Assert.isFalse(pe.Success__c, 'Event should be flagged as a failure');
		Assert.isTrue(pe.Message__c.contains('ENTITY_IS_DELETED'), 'Event should contain the deletion error');
	}

	@isTest
	static void publishPlatformEventWithoutExternalIdValueTest(){
		Lead leadNotDeleted = [SELECT Id, Email FROM Lead WHERE LastName =: STRING_DELETE_CRITERIA];

		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		batch.publishPeKo = true;
		batch.publishPePerChunk = false;
		//the lead has no email
		batch.externalId = 'Email';

		Test.startTest();
		List<PurgeSObjectBatch__e> events = batch.publishPlatformEventIfEnabled(
			new List<Database.DeleteResult>{getFailedDeleteResult()}, new List<SObject>{leadNotDeleted});
		Test.stopTest();

		Assert.isTrue(String.isBlank(events.get(0).ExternalId__c), 'External id should be empty when the record has no value');
	}

	@isTest
	static void publishPlatformEventPerChunkTest(){
		//Doe is deleted, TO-BE-DELETED fails to be deleted
		List<Lead> leads = [SELECT Id, LastName FROM Lead ORDER BY LastName];
		Database.DeleteResult successResult = (Database.DeleteResult) JSON.deserialize(
			'{"success":true,"id":"' + leads.get(0).Id + '","errors":[]}', Database.DeleteResult.class);

		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		batch.publishPeOk = true;
		batch.publishPeKo = true;
		batch.publishPePerChunk = true;
		batch.externalId = 'LastName';

		Test.startTest();
		List<PurgeSObjectBatch__e> events = batch.publishPlatformEventIfEnabled(
			new List<Database.DeleteResult>{successResult, getFailedDeleteResult()}, leads);
		Test.stopTest();

		Assert.areEqual(2, events.size(), 'One event per result should be published for the chunk');
		for(PurgeSObjectBatch__e pe : events){
			Assert.isNull(pe.Id__c, 'Events published per chunk should not reference a single record');
			List<Object> records = (List<Object>) JSON.deserializeUntyped(pe.Records__c);
			Assert.areEqual(1, records.size(), 'Each event should contain one record');

			Map<String, Object> record = (Map<String, Object>) records.get(0);
			Lead expectedLead = pe.Success__c ? leads.get(0) : leads.get(1);
			Assert.areEqual(String.valueOf(expectedLead.Id), record.get('id'), 'Event should reference the record');
			Assert.areEqual(expectedLead.LastName, record.get('externalId'), 'Event should contain the record external id');
			Assert.areEqual(!pe.Success__c, record.containsKey('message'), 'Only the failed record should have a message');
		}
	}

	@isTest
	static void publishPlatformEventPerChunkSplitTest(){
		List<Lead> leads = [SELECT Id FROM Lead];

		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		batch.publishPeKo = true;
		batch.publishPePerChunk = true;
		batch.externalId = null;
		//each record takes around 80 characters: two records can't fit in the same event
		PurgeSObjectBatch.recordsMaxLength = 100;

		Test.startTest();
		List<PurgeSObjectBatch__e> events = batch.publishPlatformEventIfEnabled(
			new List<Database.DeleteResult>{getFailedDeleteResult(), getFailedDeleteResult()}, leads);
		Test.stopTest();

		Assert.areEqual(2, events.size(), 'Records should be split between events when they exceed the field length');
		for(PurgeSObjectBatch__e pe : events){
			Assert.isTrue(pe.Records__c.length() <= 100, 'Records should not exceed the field length');
		}
	}

	@isTest
	static void purgeSObjectInvalidConfigurationTest(){
		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		batch.publishPeKo = true;
		batch.whereClause = 'UnknownField__c = true';

		Test.startTest();
		Id jobId = Database.executeBatch(batch);
		Test.stopTest();

		AsyncApexJob job = [SELECT Status, NumberOfErrors FROM AsyncApexJob WHERE Id =: jobId];
		Assert.areEqual('Completed', job.Status, 'An invalid configuration should not make the batch fail');
		Assert.areEqual(0, job.NumberOfErrors, 'An invalid configuration should not make the batch fail');
		Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE IsDeleted = true ALL ROWS], 'No lead should be deleted');
	}

	@isTest
	static void purgeSObjectNoSettingLeftTest(){
		Test.startTest();
		//Sequence__c can't be greater than 99: there is no setting left to process
		Id jobId = Database.executeBatch(new PurgeSObjectBatch(99));
		Test.stopTest();

		AsyncApexJob job = [SELECT Status, NumberOfErrors FROM AsyncApexJob WHERE Id =: jobId];
		Assert.areEqual('Completed', job.Status, 'The batch should complete when there is nothing to purge');
		Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE IsDeleted = true ALL ROWS], 'No lead should be deleted');
	}

	@isTest
	static void getBatchSizeTest(){
		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		batch.batchSize = null;
		Assert.areEqual(200, batch.getBatchSize(), 'The default batch size should be used when BatchSize__c is empty');

		batch.batchSize = 50;
		Assert.areEqual(50, batch.getBatchSize(), 'The batch size of the CMDT should be used');
	}

	@isTest
	static void recordResultsTest(){
		Lead deletedLead = [SELECT Id FROM Lead WHERE LastName = 'Doe'];
		List<Database.DeleteResult> results = new List<Database.DeleteResult>{
			(Database.DeleteResult) JSON.deserialize('{"success":true,"id":"' + deletedLead.Id + '","errors":[]}', Database.DeleteResult.class),
			getFailedDeleteResult(),
			getFailedDeleteResult()
		};
		//more distinct errors than the summary keeps
		for(Integer i = 0; i < 12; i++){
			results.add(getFailedDeleteResult('error ' + i));
		}

		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		batch.recordResults(results);

		Assert.areEqual(1, batch.deletedCount, 'One record should be counted as deleted');
		Assert.areEqual(14, batch.failedCount, 'All the failed records should be counted');
		Assert.areEqual(10, batch.errorSamples.size(), 'Only the first 10 distinct errors should be kept');
		Assert.isTrue(batch.errorSamples.get(0).contains('entity is deleted'), 'Identical errors should be kept once');
	}

	@isTest
	static void errorSummaryEmailTest(){
		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		batch.sobjectName = 'Lead';
		batch.whereClause = 'LastName = \'Doe\'';
		batch.batchSize = 50;
		Assert.isNull(batch.getErrorSummaryEmail(0, null), 'No email should be sent when there is no error');

		batch.deletedCount = 5;
		batch.failedCount = 2;
		batch.errorSamples.add('[ENTITY_IS_DELETED] () entity is deleted');
		batch.runErrors.add('The purge of the next sequence could not be started');
		Messaging.SingleEmailMessage email = batch.getErrorSummaryEmail(1, 'First chunk error');

		Assert.areEqual(UserInfo.getUserId(), email.getTargetObjectId(), 'The email should be sent to the running user');
		Assert.areEqual('Purge of Lead completed with errors', email.getSubject(), 'The subject should name the SObject');
		String body = email.getPlainTextBody();
		Assert.isTrue(body.contains('Records deleted: 5'), 'The email should contain the deleted records count');
		Assert.isTrue(body.contains('Records not deleted: 2'), 'The email should contain the failed records count');
		Assert.isTrue(body.contains('Chunks not processed because of an unhandled error: 1 (first error: First chunk error)'), 'The email should contain the failed chunks');
		Assert.isTrue(body.contains('- The purge of the next sequence could not be started'), 'The email should contain the run errors');
		Assert.isTrue(body.contains('- [ENTITY_IS_DELETED] () entity is deleted'), 'The email should contain the deletion errors');
		Assert.isTrue(body.contains('- WHERE clause: LastName = \'Doe\''), 'The email should contain the WHERE clause');
		Assert.isTrue(body.contains('- Batch size: 50'), 'The email should contain the batch size');
	}

	/**
	 * @description Returns a failed DeleteResult: it has no id, like the ones returned by Database.delete
	 * @return `Database.DeleteResult` Failed DeleteResult
	 */
	private static Database.DeleteResult getFailedDeleteResult(){
		return getFailedDeleteResult('entity is deleted');
	}

	/**
	 * @description Returns a failed DeleteResult with a specific error message
	 * @param message Error message
	 * @return `Database.DeleteResult` Failed DeleteResult
	 */
	private static Database.DeleteResult getFailedDeleteResult(String message){
		return (Database.DeleteResult) JSON.deserialize(
			'{"success":false,"errors":[{"statusCode":"ENTITY_IS_DELETED","message":"' + message + '","fields":[]}]}',
			Database.DeleteResult.class);
	}
}
