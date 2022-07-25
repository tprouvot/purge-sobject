@isTest
private class PurgeSObjectBatch_Test {

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
		Lead leadToBeDeleted = [SELECT Id, ToBeDeleted__c, IsDeleted FROM Lead WHERE LastName =: STRING_DELETE_CRITERIA];
		Lead leadNotToBeDeleted = [SELECT Id, ToBeDeleted__c, IsDeleted FROM Lead WHERE Id != :leadToBeDeleted.Id];

		System.assertEquals(true, leadToBeDeleted.ToBeDeleted__c, 'ToBeDeleted__c should be true');
		System.assertEquals(false, leadToBeDeleted.IsDeleted, 'IsDeleted should be false');
		System.assertEquals(false, leadNotToBeDeleted.ToBeDeleted__c, 'ToBeDeleted__c should be false');
		Test.startTest();

		Database.executeBatch(new PurgeSObjectBatch());
		Test.stopTest();

		leadToBeDeleted = [SELECT Id, IsDeleted FROM Lead WHERE Id =:leadToBeDeleted.Id ALL ROWS];
		System.assertEquals(true, leadToBeDeleted.IsDeleted, 'Lead should be deleted');
	}
}