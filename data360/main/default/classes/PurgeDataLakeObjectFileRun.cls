/**
 * @description One-time purge of the primary keys listed in files (ContentDocument), without custom metadata.
 * Each file is a CSV whose first line is the primary key field of the Data Lake Object, followed by one primary key per line.
 * A run is a dry run unless dryRun is set to false: it only counts and checks the primary keys of the files.
 *
 * Run it from Anonymous Apex:
 *   PurgeDataLakeObjectFileRun run = new PurgeDataLakeObjectFileRun();
 *   run.dataLakeObject = 'Orders__dll';
 *   run.connector = 'Ecomm_Orders';
 *   run.sourceObject = 'Orders';
 *   run.primaryKeyField = 'order_id__c';
 *   run.contentDocumentIds = new List<Id>{'069...'};
 *   // run.dryRun = false;   // uncomment to delete
 *   run.start();
 */
public with sharing class PurgeDataLakeObjectFileRun {

	public String dataLakeObject;
	public String connector;
	public String sourceObject;
	public String primaryKeyField;
	public String dataspace = PurgeDataLakeObjectRun.DEFAULT_DATASPACE;
	public Integer chunkSize = PurgeDataLakeObjectRun.DEFAULT_CHUNK_SIZE;
	public List<Id> contentDocumentIds = new List<Id>();
	public Boolean dryRun = true;

	/**
	 * @description Check the parameters and the files, and start the purge. The result is sent by email.
	 * @return `Id` Id of the first job
	 */
	public Id start(){
		PurgeDataLakeObjectRun run = new PurgeDataLakeObjectRun();
		run.mode = PurgeDataLakeObjectRun.RunMode.FILES;
		run.dataLakeObject = this.dataLakeObject;
		run.connector = this.connector;
		run.sourceObject = this.sourceObject;
		run.primaryKeyField = this.primaryKeyField;
		run.dataspace = this.dataspace;
		run.chunkSize = this.chunkSize;
		run.contentDocumentIds = this.contentDocumentIds;
		run.dryRun = this.dryRun != false;
		run.validateParameters();
		checkFiles(run.contentDocumentIds);
		if(PurgeDataLakeObjectJob.isRunning()){
			throw new PurgeDataLakeObjectRun.ConfigurationException('A purge of a Data Lake Object is already running, and Data 360 '
				+ 'accepts one open job per object: start the file run when it is done.');
		}
		return PurgeDataLakeObjectJob.start(run);
	}

	/**
	 * @description Check that the files exist, are shared with the running user, and aren't too large
	 * @param documentIds Ids of the files
	 */
	private static void checkFiles(List<Id> documentIds){
		Map<Id, ContentVersion> versions = new Map<Id, ContentVersion>();
		for(ContentVersion version : [SELECT ContentDocumentId, Title, ContentSize FROM ContentVersion
			WHERE ContentDocumentId IN :documentIds AND IsLatest = true]){
			versions.put(version.ContentDocumentId, version);
		}
		List<String> problems = new List<String>();
		for(Id documentId : documentIds){
			ContentVersion version = versions.get(documentId);
			if(version == null){
				problems.add(documentId + ' doesn\'t exist or isn\'t shared with you');
			} else if(version.ContentSize > PurgeDataLakeObjectJob.maxFileSize){
				problems.add('"' + version.Title + '" is larger than ' + (PurgeDataLakeObjectJob.maxFileSize / 1000000) + ' MB: split it');
			}
		}
		if(!problems.isEmpty()){
			throw new PurgeDataLakeObjectRun.ConfigurationException('Invalid files: ' + String.join(problems, '; ') + '.');
		}
	}
}
