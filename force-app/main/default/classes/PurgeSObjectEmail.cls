/**
 * @description Summary email of a purge, built from a Lightning email template that admins can customize in the Email Templates tab.
 * The {{Name}} placeholders of the subject and the body are replaced with the values of the run: the values aren't stored
 * in a record, so the merge fields of Salesforce can't be used. An unknown placeholder is kept as is, so that a typo is visible.
 * When the template doesn't exist, isn't active or isn't visible to the running user, the built-in plain text email is sent.
 */
public with sharing class PurgeSObjectEmail {

	private static final Pattern PLACEHOLDER = Pattern.compile('\\{\\{\\s*(\\w+)\\s*\\}\\}');
	private static final String EMPTY_LIST = 'None';
	private static final String EMPTY_VALUE = '-';

	//set by the tests: false to send the built-in email even when the template is deployed
	@TestVisible
	private static Boolean useTemplates = true;
	//set by the tests: template used instead of the record of the org
	@TestVisible
	private static EmailTemplate templateOverride;

	private String templateName;
	private Map<String, Object> values = new Map<String, Object>();

	/**
	 * @description Email based on a template
	 * @param templateName DeveloperName of the email template
	 */
	public PurgeSObjectEmail(String templateName){
		this.templateName = templateName;
		this.values.put('RecipientName', UserInfo.getName());
		this.values.put('OrgName', UserInfo.getOrganizationName());
		this.values.put('RunDate', Datetime.now().format());
	}

	/**
	 * @description Set the value of a placeholder
	 * @param name Name of the placeholder, without the braces
	 * @param value Text, number, Boolean (Yes or No), or list of texts (bullet list, None when empty). null is shown as -.
	 * @return `PurgeSObjectEmail` This email
	 */
	public PurgeSObjectEmail put(String name, Object value){
		this.values.put(name, value);
		return this;
	}

	/**
	 * @description Returns the email for the running user
	 * @param defaultSubject Subject of the built-in email, used without the template
	 * @param defaultBody Plain text of the built-in email, used without the template
	 * @return `Messaging.SingleEmailMessage` Email
	 */
	public Messaging.SingleEmailMessage build(String defaultSubject, String defaultBody){
		Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
		email.setTargetObjectId(UserInfo.getUserId());
		email.setSaveAsActivity(false);

		EmailTemplate template = getTemplate();
		if(template == null){
			email.setSubject(defaultSubject);
			email.setPlainTextBody(defaultBody);
			return email;
		}
		email.setSubject(String.isNotBlank(template.Subject) ? render(template.Subject, false) : defaultSubject);
		String html = render(template.HtmlValue, true);
		email.setHtmlBody(html);
		email.setPlainTextBody(String.isNotBlank(template.Body) ? render(template.Body, false) : html.stripHtmlTags());
		return email;
	}

	/**
	 * @description Replace the placeholders of a text
	 * @param text Subject or body of the template
	 * @param html true to escape the values and render the lists as HTML
	 * @return `String` Text with the values
	 */
	@TestVisible
	private String render(String text, Boolean html){
		if(String.isBlank(text)){
			return text;
		}
		List<String> parts = new List<String>();
		Matcher m = PLACEHOLDER.matcher(text);
		Integer last = 0;
		while(m.find()){
			parts.add(text.substring(last, m.start()));
			String name = m.group(1);
			parts.add(this.values.containsKey(name) ? format(this.values.get(name), html) : m.group(0));
			last = m.end();
		}
		parts.add(text.substring(last));
		return String.join(parts, '');
	}

	private static String format(Object value, Boolean html){
		if(value == null){
			return EMPTY_VALUE;
		}
		if(value instanceof Boolean){
			return (Boolean) value ? 'Yes' : 'No';
		}
		if(value instanceof List<Object>){
			List<String> items = new List<String>();
			for(Object item : (List<Object>) value){
				items.add(html ? escape(String.valueOf(item)) : String.valueOf(item));
			}
			if(items.isEmpty()){
				return EMPTY_LIST;
			}
			return html ? '<ul><li>' + String.join(items, '</li><li>') + '</li></ul>' : '- ' + String.join(items, '\n- ');
		}
		String text = String.valueOf(value);
		return html ? escape(text) : text;
	}

	private static String escape(String text){
		return text.escapeHtml4().replace('\n', '<br/>');
	}

	private EmailTemplate getTemplate(){
		if(templateOverride != null){
			return templateOverride;
		}
		if(!useTemplates){
			return null;
		}
		try {
			List<EmailTemplate> templates = [SELECT Subject, HtmlValue, Body FROM EmailTemplate
				WHERE DeveloperName = :this.templateName AND IsActive = true LIMIT 1];
			return templates.isEmpty() || String.isBlank(templates.get(0).HtmlValue) ? null : templates.get(0);
		} catch (Exception e) {
			System.debug(LoggingLevel.WARN, 'The email template ' + this.templateName + ' is ignored: ' + e.getMessage());
			return null;
		}
	}
}
