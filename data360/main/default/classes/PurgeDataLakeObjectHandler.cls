/**
 * @description Handler of the Data 360 module, loaded by PurgeSObjectBatch when the data360 folder is deployed.
 * It purges the settings of the Data Lake Objects (__dll) with the Ingestion API, and rejects the Data Model Objects (__dlm).
 */
public with sharing class PurgeDataLakeObjectHandler implements PurgeSObjectHandler {

	/**
	 * @description The settings of the Data Lake Objects and the Data Model Objects are handled by the Data 360 module
	 * @param setting Custom metadata record
	 * @return `Boolean` true for an API name ending with __dll or __dlm
	 */
	public Boolean handles(PurgeSObjectSetting__mdt setting){
		String name = setting?.SObjectApiName__c == null ? '' : setting.SObjectApiName__c.trim().toLowerCase();
		return name.endsWith('__dll') || name.endsWith('__dlm');
	}

	/**
	 * @description Start the purge of a Data Lake Object. The chain continues with the next sequence when the job is closed.
	 * @param setting Custom metadata record, with all its fields
	 */
	public void start(PurgeSObjectSetting__mdt setting){
		if(setting.SObjectApiName__c.trim().toLowerCase().endsWith('__dlm')){
			throw new PurgeDataLakeObjectRun.ConfigurationException(setting.SObjectApiName__c.trim()
				+ ' is a Data Model Object: Data 360 records can only be deleted from their Data Lake Object (__dll). '
				+ 'The Data Model Object is updated after the next batch run of Data 360.');
		}
		PurgeDataLakeObjectRun run = new PurgeDataLakeObjectRun();
		run.mode = PurgeDataLakeObjectRun.RunMode.QUERY;
		run.settingName = setting.DeveloperName;
		run.sequence = setting.Sequence__c != null ? Integer.valueOf(setting.Sequence__c) : null;
		run.dataLakeObject = setting.SObjectApiName__c;
		run.connector = setting.IngestionConnector__c;
		run.sourceObject = setting.IngestionObject__c;
		run.primaryKeyField = setting.PrimaryKeyField__c;
		run.dataspace = setting.Dataspace__c;
		run.whereClause = setting.WhereClauseToBeDeleted__c;
		run.chunkSize = setting.ChunkSize__c != null ? Integer.valueOf(setting.ChunkSize__c) : null;
		run.dryRun = setting.DryRun__c == true;
		run.publishPeOk = setting.PublishPlatformEventOk__c == true;
		run.publishPeKo = setting.PublishPlatformEventKo__c == true;
		PurgeDataLakeObjectJob.start(run);
	}

	/**
	 * @description Indicates if a purge of a Data Lake Object is still running: the scheduled purge is then skipped
	 * @return `Boolean` true while a PurgeDataLakeObjectJob is queued or running
	 */
	public Boolean isRunning(){
		return PurgeDataLakeObjectJob.isRunning();
	}
}
