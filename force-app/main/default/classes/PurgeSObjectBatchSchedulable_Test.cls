@isTest
private class PurgeSObjectBatchSchedulable_Test {

	@isTest
	static void purgeSObjectSchedulableTest(){
		Datetime tomorrow = System.today().addDays(1);
		String cron = '0 0 0 ' + tomorrow.day() + ' ' + tomorrow.month() + ' ? ' + tomorrow.year();
		String jobId = System.schedule('TestSchedule', cron , new PurgeSObjectBatchSchedulable());

		// Get the information from the CronTrigger API object
		CronTrigger ct = [SELECT Id, CronExpression, TimesTriggered, NextFireTime FROM CronTrigger WHERE id = :jobId];

		// Verify the expressions are the same
		System.assertEquals(cron, ct.CronExpression, 'CronExpression should be equals');

		// Verify the job has not run
		System.assertEquals(0, ct.TimesTriggered, 'Job should not run');
	}

	@isTest
	static void startPurgeTest(){
		Test.startTest();
		new PurgeSObjectBatchSchedulable().execute(null);
		Integer jobs = [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'PurgeSObjectBatch'];
		Test.stopTest();

		Assert.areEqual(1, jobs, 'The scheduled job should start the purge');
	}

	@isTest
	static void skipPurgeWhenRunningTest(){
		Test.startTest();
		Database.executeBatch(new PurgeSObjectBatch());
		new PurgeSObjectBatchSchedulable().execute(null);
		Integer jobs = [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'PurgeSObjectBatch'];
		Test.stopTest();

		Assert.areEqual(1, jobs, 'The scheduled job should not start a purge while another one is running');
	}
}
