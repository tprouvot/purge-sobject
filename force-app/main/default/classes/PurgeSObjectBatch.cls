/**
 * @description This class is used to clean the database by performing records deletion
 */
public with sharing class PurgeSObjectBatch implements Database.Batchable<sObject>{

	private Integer sequence;
	private Integer lastSequence;

	@TestVisible
	private String sobjectName;

	/**
	 * @description Instanciate constructor with parameters, is called in the finish method
	 * @param  sequence		Defines the Object Sequence to delete in this instance
	 * @param  lastSequence Defines the last Object sequence to execute
	 */
	public PurgeSObjectBatch(Integer sequence, Integer lastSequence){
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
		String query = 'SELECT Id FROM ' + String.escapeSingleQuotes(this.sobjectName) + ' WHERE ToBeDeleted__c=true';
		return Database.getQueryLocator(query);
	}

	public void execute(Database.BatchableContext BC, List<sObject> scope){
		SObjectType sObjType = ((SObject) Type.forName(this.sobjectName).newInstance()).getSObjectType();
		if (sObjType.getDescribe().isDeletable()) {
			Database.delete(scope, false);
		}
	}

	/**
	 * @description Call the PurgeSObjectBatch to handle the deletion of the next records Object to parse
	 * @param  BC BatchableContext
	 */
	public void finish(Database.BatchableContext BC){
		//call the batch only if the Object list is not the last one
		if(sequence < lastSequence){
			Database.executeBatch(new PurgeSObjectBatch(sequence, lastSequence));
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
		List<PurgeSObjectSetting__mdt> settings = [SELECT SObjectApiName__c, Sequence__c
		FROM PurgeSObjectSetting__mdt WHERE Sequence__c >:sequence ORDER BY Sequence__c];

		//store the lastIndex to end the process
		if(lastSequence == null){
			//since the list is sorted by sequence, the last index is the last sequence
			this.lastSequence = Integer.valueOf(settings.get(settings.size() - 1).Sequence__c);
		}
		//use the first item of the list
		this.sequence = Integer.valueOf(settings.get(0).Sequence__c);
		this.sobjectName = settings.get(0).SObjectApiName__c;
	}
}