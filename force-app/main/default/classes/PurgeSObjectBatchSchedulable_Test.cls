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

	@isTest
	static void skipPurgeWhenHandlerRunningTest(){
		RunningHandler handler = new RunningHandler();
		PurgeSObjectBatch.handlersOverride = new List<PurgeSObjectHandler>{handler};

		Test.startTest();
		new PurgeSObjectBatchSchedulable().execute(null);
		Integer jobs = [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'PurgeSObjectBatch'];
		Test.stopTest();

		Assert.areEqual(0, jobs, 'The scheduled job should not start a purge while a job of an optional module is running');
	}

	/**
	 * @description Handler of an optional module that is still running
	 */
	private class RunningHandler implements PurgeSObjectHandler {
		public Boolean handles(PurgeSObjectSetting__mdt setting){
			return false;
		}
		public void start(PurgeSObjectSetting__mdt setting){
			return;
		}
		public Boolean isRunning(){
			return true;
		}
	}
}
