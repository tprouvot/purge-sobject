/**
 * @description Calls of the Data 360 APIs used to purge the Data Lake Objects:
 * - the Data 360 token exchange and the Data 360 Connect REST API, through the PurgeData360 named credential,
 * - the Ingestion API bulk jobs, on the tenant endpoint returned by the token exchange.
 * The Data 360 token is kept in memory for the current transaction only.
 */
public with sharing class PurgeDataLakeObjectApi {

	@TestVisible
	private static final String NAMED_CREDENTIAL = 'callout:PurgeData360';
	private static final String CONNECT_API = NAMED_CREDENTIAL + '/services/data/v68.0/ssot';
	//the named credential doesn't generate the Authorization header: the token exchange rejects it
	private static final String CREDENTIAL_TOKEN = 'Bearer {!$Credential.OAuthToken}';
	private static final Integer TIMEOUT = 120000;

	private String tenantUrl;
	private String accessToken;

	/**
	 * @description Error returned by a Data 360 API
	 */
	public virtual class ApiException extends Exception {
		public Integer statusCode;
	}

	/**
	 * @description Error that can disappear when the request is sent again later:
	 * too many requests (429), conflict with a job of the same object (409) or server error (5xx)
	 */
	public class RetryableException extends ApiException {}

	/**
	 * @description Returns the metadata of a Data Lake Object: fields, primary key, record modified field and data spaces
	 * @param name API name of the Data Lake Object
	 * @return `Map<String, Object>` Data Lake Object, null when it doesn't exist
	 */
	public Map<String, Object> getDataLakeObject(String name){
		HttpResponse res = send(newConnectRequest('GET', '/data-lake-objects/' + EncodingUtil.urlEncode(name, 'UTF-8')), new Set<Integer>{200, 404});
		if(res.getStatusCode() == 404){
			return null;
		}
		List<Object> objects = (List<Object>) toMap(res).get('dataLakeObjects');
		return objects == null || objects.isEmpty() ? null : (Map<String, Object>) objects.get(0);
	}

	/**
	 * @description Returns the Ingestion API connectors of the org
	 * @return `List<Object>` Connections, with their name, label and tenant endpoint
	 */
	public List<Object> getIngestionConnections(){
		HttpResponse res = send(newConnectRequest('GET', '/connections?connectorType=IngestApi&limit=200'), new Set<Integer>{200});
		List<Object> connections = (List<Object>) toMap(res).get('connections');
		return connections != null ? connections : new List<Object>();
	}

	/**
	 * @description Returns the data streams of a connection
	 * @param connectionName API name of the connection, with its generated suffix
	 * @return `List<Object>` Data streams, with their connector type and Data Lake Object
	 */
	public List<Object> getDataStreams(String connectionName){
		HttpResponse res = send(newConnectRequest('GET', '/data-streams?limit=200&connectionName=' + EncodingUtil.urlEncode(connectionName, 'UTF-8')),
			new Set<Integer>{200});
		List<Object> streams = (List<Object>) toMap(res).get('dataStreams');
		return streams != null ? streams : new List<Object>();
	}

	/**
	 * @description Create an Ingestion API bulk job that deletes records
	 * @param sourceName Name of the Ingestion API connector
	 * @param objectName Object of the connector
	 * @return `Map<String, Object>` Job: id, operation, state and createdDate.
	 * While a job of the object is open, Data 360 returns this job instead of creating a new one.
	 */
	public Map<String, Object> createDeleteJob(String sourceName, String objectName){
		HttpRequest req = newTenantRequest('POST', '/api/v1/ingest/jobs');
		req.setHeader('Content-Type', 'application/json');
		req.setBody(JSON.serialize(new Map<String, Object>{'object' => objectName, 'sourceName' => sourceName, 'operation' => 'delete'}));
		return toMap(send(req, new Set<Integer>{200, 201}));
	}

	/**
	 * @description Upload a CSV file of primary keys to the job
	 * @param jobId Id of the job
	 * @param csv CSV without header: the primary key, and the record version when the Data Lake Object has a record modified field
	 */
	public void uploadCsv(String jobId, String csv){
		HttpRequest req = newTenantRequest('PUT', '/api/v1/ingest/jobs/' + jobId + '/batches');
		req.setHeader('Content-Type', 'text/csv');
		req.setBody(csv);
		send(req, new Set<Integer>{200, 201, 202});
	}

	/**
	 * @description Close the job (UploadComplete): Data 360 starts to process the uploaded files
	 * @param jobId Id of the job
	 * @return `Map<String, Object>` Job
	 */
	public Map<String, Object> closeJob(String jobId){
		return updateJobState(jobId, 'UploadComplete');
	}

	/**
	 * @description Abort the job: Data 360 discards the uploaded files. Only an open job can be aborted.
	 * @param jobId Id of the job
	 * @return `Map<String, Object>` Job
	 */
	public Map<String, Object> abortJob(String jobId){
		return updateJobState(jobId, 'Aborted');
	}

	/**
	 * @description Returns the job, with its state: Open, UploadComplete, InProgress, JobComplete, Failed or Aborted
	 * @param jobId Id of the job
	 * @return `Map<String, Object>` Job
	 */
	public Map<String, Object> getJob(String jobId){
		return toMap(send(newTenantRequest('GET', '/api/v1/ingest/jobs/' + jobId), new Set<Integer>{200}));
	}

	private Map<String, Object> updateJobState(String jobId, String state){
		HttpRequest req = newTenantRequest('PATCH', '/api/v1/ingest/jobs/' + jobId);
		req.setHeader('Content-Type', 'application/json');
		req.setBody(JSON.serialize(new Map<String, Object>{'state' => state}));
		return toMap(send(req, new Set<Integer>{200}));
	}

	/**
	 * @description Exchange the OAuth token of the PurgeData360 named credential for a Data 360 token
	 */
	private void authenticate(){
		if(this.accessToken != null){
			return;
		}
		HttpRequest req = new HttpRequest();
		req.setEndpoint(NAMED_CREDENTIAL + '/services/a360/token');
		req.setMethod('POST');
		req.setTimeout(TIMEOUT);
		req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
		req.setBody('grant_type=urn:salesforce:grant-type:external:cdp'
			+ '&subject_token={!$Credential.OAuthToken}'
			+ '&subject_token_type=urn:ietf:params:oauth:token-type:access_token');
		HttpResponse res = new Http().send(req);
		Map<String, Object> body = res.getBody().trim().startsWith('{') ? toMap(res) : new Map<String, Object>();
		if(res.getStatusCode() != 200 || body.get('access_token') == null || body.get('instance_url') == null){
			ApiException e = new ApiException('The Data 360 token could not be obtained (' + res.getStatusCode() + ' '
				+ (body.containsKey('error_description') ? String.valueOf(body.get('error_description')) : 'unexpected response') + '). '
				+ 'Check the consumer key and secret of the default principal of the Purge Data 360 external credential, '
				+ 'and the CDPIngest scope of the Purge Data 360 external client app.');
			e.statusCode = res.getStatusCode();
			throw e;
		}
		this.accessToken = (String) body.get('access_token');
		String instanceUrl = (String) body.get('instance_url');
		this.tenantUrl = instanceUrl.startsWith('https://') ? instanceUrl : 'https://' + instanceUrl;
	}

	private HttpRequest newConnectRequest(String method, String path){
		HttpRequest req = new HttpRequest();
		req.setEndpoint(CONNECT_API + path);
		req.setMethod(method);
		req.setTimeout(TIMEOUT);
		req.setHeader('Authorization', CREDENTIAL_TOKEN);
		return req;
	}

	private HttpRequest newTenantRequest(String method, String path){
		authenticate();
		HttpRequest req = new HttpRequest();
		req.setEndpoint(this.tenantUrl + path);
		req.setMethod(method);
		req.setTimeout(TIMEOUT);
		req.setHeader('Authorization', 'Bearer ' + this.accessToken);
		return req;
	}

	/**
	 * @description Send the request and check the status code of the response
	 * @param req Request
	 * @param expected Status codes of a successful response
	 * @return `HttpResponse` Response
	 */
	private HttpResponse send(HttpRequest req, Set<Integer> expected){
		HttpResponse res = new Http().send(req);
		Integer code = res.getStatusCode();
		if(expected.contains(code)){
			return res;
		}
		String message = req.getMethod() + ' ' + req.getEndpoint().substringBefore('?').replace(NAMED_CREDENTIAL, '')
			.replace(String.valueOf(this.tenantUrl), '') + ' returned ' + code + ': ' + getErrorMessage(res);
		ApiException e = code == 409 || code == 429 || code >= 500 ? new RetryableException(message) : new ApiException(message);
		e.statusCode = code;
		throw e;
	}

	private static String getErrorMessage(HttpResponse res){
		String body = res.getBody();
		if(String.isBlank(body)){
			return res.getStatus();
		}
		try {
			Object parsed = JSON.deserializeUntyped(body);
			Map<String, Object> error = parsed instanceof List<Object> ? (Map<String, Object>) ((List<Object>) parsed).get(0) : (Map<String, Object>) parsed;
			for(String key : new List<String>{'message', 'error_description', 'error'}){
				if(error.get(key) != null){
					return String.valueOf(error.get(key));
				}
			}
		} catch (Exception e) {
			//not a JSON error: use the beginning of the body
			System.debug(LoggingLevel.FINE, 'Unexpected error body: ' + e.getMessage());
		}
		return body.left(300);
	}

	private static Map<String, Object> toMap(HttpResponse res){
		String body = res.getBody();
		return String.isBlank(body) ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(body);
	}
}
