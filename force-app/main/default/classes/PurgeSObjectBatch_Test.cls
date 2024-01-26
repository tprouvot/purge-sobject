@isTest
private class PurgeSObjectBatch_Test {
	//TODO This test class must be adapted to your implemenation and SObjects to purge
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
}
