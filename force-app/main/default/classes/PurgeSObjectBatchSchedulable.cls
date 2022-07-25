/**
 * @description This class is used to schedule PurgeSObjectBatch class
 */
public with sharing class PurgeSObjectBatchSchedulable implements Schedulable {
	public void execute(SchedulableContext sc) {
		Database.executeBatch(new SObjectCleaningBatch());
	}
}
