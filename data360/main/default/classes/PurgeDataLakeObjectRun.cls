/**
 * @description State of the purge of a Data Lake Object (__dll), kept by the PurgeDataLakeObjectJob Queueable jobs
 * from the validation to the final report. It contains no credential: the Data 360 token is requested again in each job.
 */
public with sharing class PurgeDataLakeObjectRun {

	/**
	 * @description QUERY: scheduled purge of a PurgeSObjectSetting__mdt record, the records to delete are selected with a WHERE clause.
	 * FILES: one-time purge of the primary keys listed in files, started with PurgeDataLakeObjectFileRun.
	 */
	public enum RunMode { QUERY, FILES }

	public static final String DEFAULT_DATASPACE = 'default';
	public static final Integer DEFAULT_CHUNK_SIZE = 50000;
	public static final Integer MIN_CHUNK_SIZE = 1000;
	public static final Integer MAX_CHUNK_SIZE = 100000;
	//the Ingestion API accepts up to 100 files per job
	public static final Integer MAX_FILES = 100;

	//configuration
	public RunMode mode;
	public String settingName;
	public Integer sequence;
	public String dataLakeObject;
	public String connector;
	public String sourceObject;
	public String primaryKeyField;
	public String dataspace = DEFAULT_DATASPACE;
	public String whereClause;
	public Integer chunkSize = DEFAULT_CHUNK_SIZE;
	public Boolean dryRun = false;
	public Boolean publishPeOk = false;
	public Boolean publishPeKo = false;
	public List<Id> contentDocumentIds = new List<Id>();

	//read from the metadata of the Data Lake Object during the validation
	public String recordModifiedField;
	//second column of the CSV files when the Data Lake Object has a record modified field
	public String recordVersion;

	//progress
	public Datetime startedAt;
	public String jobId;
	public String jobState;
	public Long processingTime;
	public Datetime closedAt;
	public String queryId;
	public Long offset = 0;
	public Long matched;
	public Long queried = 0;
	public Long submitted = 0;
	public Integer files = 0;
	public Integer filesOfLastPage = 0;
	public Integer fileIndex = 0;
	public Long stillPresent;
	public Long checked = 0;
	public Long checkTarget;
	public Integer checkFileIndex = 0;
	public Integer checkLineOffset = 0;
	public Integer attempts = 0;
	public Boolean chainContinued = false;
	public Boolean finished = false;
	public List<String> errors = new List<String>();
	public List<String> warnings = new List<String>();

	/**
	 * @description Invalid parameters or configuration of the purge of a Data Lake Object
	 */
	public class ConfigurationException extends Exception {}

	/**
	 * @description Check the parameters before the first job is started
	 */
	public void validateParameters(){
		List<String> problems = new List<String>();
		if(String.isBlank(this.dataLakeObject) || !this.dataLakeObject.trim().toLowerCase().endsWith('__dll')){
			problems.add('the Data Lake Object API name must end with __dll (' + this.dataLakeObject + ')');
		}
		if(String.isBlank(this.connector)){
			problems.add('the Ingestion API connector is missing (IngestionConnector__c)');
		}
		if(String.isBlank(this.sourceObject)){
			problems.add('the object of the Ingestion API connector is missing (IngestionObject__c)');
		}
		if(String.isBlank(this.primaryKeyField)){
			problems.add('the primary key field is missing (PrimaryKeyField__c)');
		}
		if(this.mode == RunMode.QUERY && String.isBlank(this.whereClause)){
			problems.add('the WHERE clause is missing (WhereClauseToBeDeleted__c): a Data Lake Object has no default delete logic');
		}
		if(this.mode == RunMode.FILES && (this.contentDocumentIds == null || this.contentDocumentIds.isEmpty())){
			problems.add('no file to read (contentDocumentIds)');
		}
		if(this.mode == RunMode.FILES && this.contentDocumentIds != null && this.contentDocumentIds.size() > MAX_FILES){
			problems.add('a run accepts up to ' + MAX_FILES + ' files');
		}
		if(this.chunkSize == null){
			this.chunkSize = DEFAULT_CHUNK_SIZE;
		}
		if(this.chunkSize < MIN_CHUNK_SIZE || this.chunkSize > MAX_CHUNK_SIZE){
			problems.add('the chunk size must be between ' + MIN_CHUNK_SIZE + ' and ' + MAX_CHUNK_SIZE + ' (' + this.chunkSize + ')');
		}
		if(String.isBlank(this.dataspace)){
			this.dataspace = DEFAULT_DATASPACE;
		}
		if(!problems.isEmpty()){
			throw new ConfigurationException('The purge of ' + this.dataLakeObject + ' can\'t start: ' + String.join(problems, '; ') + '.');
		}
		this.dataLakeObject = this.dataLakeObject.trim();
		this.connector = this.connector.trim();
		this.sourceObject = this.sourceObject.trim();
		this.primaryKeyField = this.primaryKeyField.trim();
	}

	/**
	 * @description Indicates if the purge went as expected: no error, and no record left after the job
	 * @return `Boolean` true when the run succeeded
	 */
	public Boolean isSuccess(){
		return this.errors.isEmpty() && (this.stillPresent == null || this.stillPresent == 0);
	}
}
