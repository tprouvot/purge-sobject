/**
 * @description This class is used to schedule PurgeSObjectBatch class
 */
public with sharing class PurgeSObjectBatchSchedulable implements Schedulable {
	public void execute(SchedulableContext sc) {
		//do not start a new purge while the previous one is still running: both chains would purge the same objects
		Integer runningJobs = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex'
		AND ApexClass.Name = 'PurgeSObjectBatch' AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')];
		if(runningJobs > 0){
			System.debug(LoggingLevel.WARN, 'PurgeSObjectBatch is already running, the scheduled purge is skipped');
			return;
		}
		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		Database.executeBatch(batch, batch.getBatchSize());
	}
}
