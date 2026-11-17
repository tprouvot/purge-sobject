/**
 * @description Mock of the Data 360 APIs for the tests of the Data 360 module: the responses are chosen by HTTP method and by a
 * fragment of the endpoint, and every request is recorded. The default responses describe the Data Lake Object Orders__dll,
 * fed by the object Orders of the Ingestion API connector Ecomm.
 */
@isTest
public class PurgeDataLakeObjectMock implements HttpCalloutMock {

	public static final String DATA_LAKE_OBJECT = 'Orders__dll';
	public static final String CONNECTOR = 'Ecomm';
	public static final String CONNECTION_NAME = 'Ecomm_33e7e8ab_4e45_48ae_ab81_a09a9810a02b';
	public static final String SOURCE_OBJECT = 'Orders';
	public static final String PRIMARY_KEY = 'order_id__c';
	public static final String JOB_ID = '4d5a4477-e27f-4bc1-a219-31e79407eade';

	public List<HttpRequest> requests = new List<HttpRequest>();
	private List<Rule> rules = new List<Rule>();

	private class Rule {
		private String method;
		private String fragment;
		private List<HttpResponse> responses = new List<HttpResponse>();
	}

	/**
	 * @description Mock with the default responses of a valid configuration
	 * @return `PurgeDataLakeObjectMock` Mock
	 */
	public static PurgeDataLakeObjectMock withDefaults(){
		PurgeDataLakeObjectMock mock = new PurgeDataLakeObjectMock();
		mock.respondTo('POST', '/services/a360/token', 200,
			'{"access_token":"data360-token","instance_url":"tenant.c360a.salesforce.com","token_type":"Bearer","expires_in":28800}');
		mock.respondTo('GET', '/ssot/data-lake-objects/', 200, getDataLakeObject(null));
		mock.respondTo('GET', '/ssot/connections', 200, JSON.serialize(new Map<String, Object>{'connections' => new List<Object>{
			new Map<String, Object>{'name' => CONNECTION_NAME, 'label' => CONNECTOR, 'connectorType' => 'IngestApi'}}}));
		mock.respondTo('GET', '/ssot/data-streams', 200, JSON.serialize(new Map<String, Object>{'dataStreams' => new List<Object>{
			new Map<String, Object>{'name' => 'Ecomm_Orders_E2538C8F', 'connectorInfo' => new Map<String, Object>{'connectorType' => 'IngestApi'},
				'dataLakeObjectInfo' => new Map<String, Object>{'name' => DATA_LAKE_OBJECT}}}}));
		mock.respondTo('POST', '/api/v1/ingest/jobs', 201, getJob('delete', 'Open', Datetime.now()));
		mock.respondTo('PUT', '/batches', 202, '{"accepted":true}');
		mock.respondTo('PATCH', '/api/v1/ingest/jobs/', 200, getJob('delete', 'UploadComplete', Datetime.now()));
		mock.respondTo('GET', '/api/v1/ingest/jobs/', 200, '{"id":"' + JOB_ID + '","state":"JobComplete","totalProcessingTime":300}');
		return mock;
	}

	/**
	 * @description Returns a Data Lake Object of the Data Connect API
	 * @param recordModifiedField Record modified field, null when the data stream has none
	 * @return `String` JSON response
	 */
	public static String getDataLakeObject(String recordModifiedField){
		return JSON.serialize(new Map<String, Object>{'dataLakeObjects' => new List<Object>{new Map<String, Object>{
			'name' => DATA_LAKE_OBJECT,
			'recordModifiedFieldName' => recordModifiedField,
			'dataSpaceInfo' => new List<Object>{new Map<String, Object>{'name' => 'default'}},
			'fields' => new List<Object>{
				new Map<String, Object>{'name' => 'label__c', 'isPrimaryKey' => null},
				new Map<String, Object>{'name' => PRIMARY_KEY, 'isPrimaryKey' => true}}}}});
	}

	/**
	 * @description Returns an Ingestion API job
	 * @return `String` JSON response
	 */
	public static String getJob(String operation, String state, Datetime createdDate){
		return JSON.serialize(new Map<String, Object>{'id' => JOB_ID, 'operation' => operation, 'state' => state,
			'object' => SOURCE_OBJECT, 'sourceName' => CONNECTOR,
			'createdDate' => createdDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSSSSS\'Z\'')});
	}

	/**
	 * @description Respond to the requests of a method whose endpoint contains a fragment. Several responses for the same
	 * method and fragment are returned in order, the last one is then reused. A rule replaces the default rule of the same request.
	 * @return `PurgeDataLakeObjectMock` This mock
	 */
	public PurgeDataLakeObjectMock respondTo(String method, String fragment, Integer statusCode, String body){
		Rule rule;
		for(Rule existing : this.rules){
			if(existing.method == method && existing.fragment == fragment){
				rule = existing;
			}
		}
		if(rule == null){
			rule = new Rule();
			rule.method = method;
			rule.fragment = fragment;
			this.rules.add(rule);
		}
		HttpResponse res = new HttpResponse();
		res.setStatusCode(statusCode);
		res.setBody(body);
		rule.responses.add(res);
		return this;
	}

	/**
	 * @description Replace the responses of a method and fragment
	 * @return `PurgeDataLakeObjectMock` This mock
	 */
	public PurgeDataLakeObjectMock replace(String method, String fragment, Integer statusCode, String body){
		for(Integer i = this.rules.size() - 1; i >= 0; i--){
			if(this.rules.get(i).method == method && this.rules.get(i).fragment == fragment){
				this.rules.remove(i);
			}
		}
		return respondTo(method, fragment, statusCode, body);
	}

	public HttpResponse respond(HttpRequest req){
		this.requests.add(req);
		for(Rule rule : this.rules){
			if(rule.method == req.getMethod() && req.getEndpoint().contains(rule.fragment)){
				return rule.responses.size() > 1 ? rule.responses.remove(0) : rule.responses.get(0);
			}
		}
		HttpResponse notFound = new HttpResponse();
		notFound.setStatusCode(404);
		notFound.setBody('{"message":"No mock for ' + req.getMethod() + ' ' + req.getEndpoint() + '"}');
		return notFound;
	}

	/**
	 * @description Returns the recorded requests of a method whose endpoint contains a fragment
	 */
	public List<HttpRequest> getRequests(String method, String fragment){
		List<HttpRequest> found = new List<HttpRequest>();
		for(HttpRequest req : this.requests){
			if(req.getMethod() == method && req.getEndpoint().contains(fragment)){
				found.add(req);
			}
		}
		return found;
	}

	/**
	 * @description Mock the Data 360 SQL queries: every query returns these values in its only column, "v"
	 * @param values Values of the rows
	 */
	public static void mockQueryValues(List<String> values){
		sfsqlquery.SqlTester.clearMocks();
		ConnectApi.QuerySqlMetadataItem column = new ConnectApi.QuerySqlMetadataItem();
		column.name = 'v';
		column.type = ConnectApi.TypeEnum.VARCHAR;
		sfsqlquery.SqlTester.setMockMetadata(new List<ConnectApi.QuerySqlMetadataItem>{column});
		List<ConnectApi.QuerySqlRow> rows = new List<ConnectApi.QuerySqlRow>();
		for(String value : values){
			ConnectApi.QuerySqlRow row = new ConnectApi.QuerySqlRow();
			row.row = new List<Object>{value};
			rows.add(row);
		}
		sfsqlquery.SqlTester.setMockRows(rows);
	}

	/**
	 * @description Returns a run of the scheduled mode on Orders__dll, with its parameters checked
	 * @return `PurgeDataLakeObjectRun` Run
	 */
	public static PurgeDataLakeObjectRun newQueryRun(){
		PurgeDataLakeObjectRun run = new PurgeDataLakeObjectRun();
		run.mode = PurgeDataLakeObjectRun.RunMode.QUERY;
		run.settingName = 'Orders';
		run.sequence = 7;
		run.dataLakeObject = DATA_LAKE_OBJECT;
		run.connector = CONNECTOR;
		run.sourceObject = SOURCE_OBJECT;
		run.primaryKeyField = PRIMARY_KEY;
		run.whereClause = '"label__c" = \'old\'';
		run.chunkSize = PurgeDataLakeObjectRun.MIN_CHUNK_SIZE;
		run.publishPeOk = true;
		run.publishPeKo = true;
		run.validateParameters();
		run.startedAt = Datetime.now();
		return run;
	}
}
