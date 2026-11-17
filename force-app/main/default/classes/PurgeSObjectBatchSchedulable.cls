/**
 * @description This class is used to schedule PurgeSObjectBatch class
 */
public with sharing class PurgeSObjectBatchSchedulable implements Schedulable {
	public void execute(SchedulableContext sc) {
		//do not start a new purge while the previous one is still running: both chains would purge the same objects
		if(isPurgeRunning()){
			System.debug(LoggingLevel.WARN, 'A purge is already running, the scheduled purge is skipped');
			return;
		}
		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		Database.executeBatch(batch, batch.getBatchSize());
	}

	/**
	 * @description Indicates if a PurgeSObjectBatch job, or a job of an optional module, is still running
	 * @return `Boolean` true while a purge is running
	 */
	@TestVisible
	private static Boolean isPurgeRunning(){
		Integer runningJobs = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex'
		AND ApexClass.Name = 'PurgeSObjectBatch' AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')];
		if(runningJobs > 0){
			return true;
		}
		for(PurgeSObjectHandler handler : PurgeSObjectBatch.getHandlers()){
			if(handler.isRunning()){
				return true;
			}
		}
		return false;
	}
}
