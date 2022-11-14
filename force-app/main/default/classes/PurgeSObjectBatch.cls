/**
 * @description This class is used to clean the database by performing records deletion
 */
public with sharing class PurgeSObjectBatch implements Database.Batchable<SObject>{

	private Integer sequence;
	private Integer lastSequence;
	@TestVisible
	private Boolean publishPeOk;
	@TestVisible
	private Boolean publishPeKo;
	private String externalId;
	private String externalToBeDeleted;

	@TestVisible
	private String sobjectName;

	/**
	 * @description Instanciate constructor with parameters, is called in the finish method
	 * @param  sequence		Defines the Object Sequence to delete in this instance
	 */
	public PurgeSObjectBatch(Integer sequence){
		setParams(sequence);
	}

	/**
	 * @description Instanciate constructor without parameters, is called by the schedulable class
	 */
	public PurgeSObjectBatch() {
		setParams(null);
	}

	/**
	 * @description Build the query with the custom setting parameter with the SObject name
	 * @param  BC BatchableContext
	 * @return    QueryLocator
	 */
	public Database.QueryLocator start(Database.BatchableContext BC){
		String extId = getExternalIdValue();
		String query = 'SELECT Id' + extId + ' FROM ' + String.escapeSingleQuotes(this.sobjectName) + ' WHERE ' + getToBeDeletedField() + '=true';
		return Database.getQueryLocator(query);
	}

	public void execute(Database.BatchableContext BC, List<SObject> scope){
		SObjectType sObjType = ((SObject) Type.forName(this.sobjectName).newInstance()).getSObjectType();
		if (sObjType.getDescribe().isDeletable()) {
			List<Database.DeleteResult> drList = Database.delete(scope, false);
			if(this.publishPeOk || this.publishPeKo){
				publishPlatformEventIfEnabled(drList, scope);
			}
		}
	}

	/**
	 * @description Call the PurgeSObjectBatch to handle the deletion of the next records Object to parse
	 * @param  BC BatchableContext
	 */
	public void finish(Database.BatchableContext BC){
		//call the batch only if the Object list is not the last one
		if(sequence < lastSequence){
			Database.executeBatch(new PurgeSObjectBatch(sequence));
		}
	}

	/**
	 * @description Instanciate the parameters of the batch :the sobjectName to parse and his sequence
	 * @param  sequence Object order of execution
	 */
	public void setParams(Integer sequence){
		//if param is null it means the method was called from the scheduled job
		if(sequence == null){
			sequence = 0;
		}
		//get the next sequences to avoid issue with missing numbers
		List<PurgeSObjectSetting__mdt> settings = [SELECT SObjectApiName__c, Sequence__c, PublishPlatformEventOk__c,
		PublishPlatformEventKo__c, PlatformEventExternalId__c, ExternalToBeDeletedField__c FROM PurgeSObjectSetting__mdt
		WHERE Sequence__c >:sequence ORDER BY Sequence__c];

		//store the lastIndex to end the process
		if(lastSequence == null){
			//since the list is sorted by sequence, the last index is the last sequence
			this.lastSequence = Integer.valueOf(settings.get(settings.size() - 1).Sequence__c);
		}
		//use the first item of the list
		PurgeSObjectSetting__mdt sett = settings.get(0);
		this.sequence = Integer.valueOf(sett.Sequence__c);
		this.sobjectName = sett.SObjectApiName__c;
		this.publishPeOk = sett.PublishPlatformEventOk__c;
		this.publishPeKo = sett.PublishPlatformEventKo__c;
		this.externalId = sett.PlatformEventExternalId__c;
		this.externalToBeDeleted = sett.ExternalToBeDeletedField__c;
	}

	/**
	 * @description Publish platform events if enabled from the CMDT configuration.
	 * @param drList List<Database.DeleteResult>
	 * @param scope List<SObject>
	 */
	public void publishPlatformEventIfEnabled(List<Database.DeleteResult> drList, List<SObject> scope){

		List<PurgeSObjectBatch__e> peList = new List<PurgeSObjectBatch__e>();
		//create map to be able to get externalId
		Map<Id, SObject> scopeMap = new Map<Id, SObject>(scope);

		for(Database.DeleteResult dr : drList){
			if((dr.isSuccess() && this.publishPeOk) || (!dr.isSuccess() && this.publishPeKo)){
				String recId = dr.getId();
				String extId = String.isNotEmpty(this.externalId) ? String.valueOf(scopeMap.get(recId).get(this.externalId)) : '';

				PurgeSObjectBatch__e pe = new PurgeSObjectBatch__e(Id__c = recId, Success__c = dr.isSuccess(),
				ExternalId__c = extId, SObject__c = this.sobjectName, Message__c = getError(dr.getErrors()));
				peList.add(pe);
			}
		}

		List<Database.SaveResult> results = EventBus.publish(peList);
		for (Database.SaveResult sr : results) {
			if (!sr.isSuccess()) {
				for(Database.Error err : sr.getErrors()) {
					System.debug(LoggingLevel.ERROR ,'Error : ' + err.getStatusCode() + ' - ' + err.getMessage());
				}
			}
		}
	}

	/**
	 * @description Returns the externalId field from the CMDT if not empty
	 * @return ExternalId field if not empty and platform event publication is checked
	 */
	public String getExternalIdValue(){
		String ext = '';
		if((this.publishPeOk || this.publishPeKo) && String.isNotBlank(this.externalId)){
			ext = ', ' + this.externalId;
		}
		return ext;
	}

	/**
	 * @description Returns formated Database.Error to String
	 * @param errors
	 * @return  `String` Database.Error information (statusCdoe, fields and message)
	 */
	public String getError(List<Database.Error> errors){
		String error = '';
		for (Database.Error er: errors) {
			error += '[' + er.getStatusCode() + '] ' + er.getFields() + ' ' + er.getMessage();
		}
		return error;
	}

	/**
	 * @description Allow user to define another field to be considered for deletion rules
	 * @return  `String` externalToBeDeleted if not blank, ToBeDeleted__c otherwise
	 */
	public String getToBeDeletedField(){
		return String.isNotBlank(this.externalToBeDeleted) ? this.externalToBeDeleted : 'ToBeDeleted__c';
	}
}