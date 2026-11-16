@isTest
private class PurgeSObjectEmail_Test {

	@isTest
	static void templatePlaceholdersAreReplacedTest(){
		PurgeSObjectEmail.templateOverride = new EmailTemplate(Subject = 'Purge of {{ObjectName}}: {{Status}}',
			HtmlValue = '<p>{{ RecipientName }}: {{Count}} {{Flag}} {{Missing}} {{Unknown}}</p>{{Errors}}{{NoErrors}}');

		Messaging.SingleEmailMessage email = new PurgeSObjectEmail('Any_Template')
			.put('ObjectName', 'Lead')
			.put('Status', 'dry run')
			.put('Count', 12)
			.put('Flag', true)
			.put('Missing', null)
			.put('Errors', new List<String>{'<b>first</b>', 'second'})
			.put('NoErrors', new List<String>())
			.build('Default subject', 'Default body');

		Assert.areEqual('Purge of Lead: dry run', email.getSubject(), 'The placeholders of the subject should be replaced');
		Assert.areEqual('<p>' + UserInfo.getName().escapeHtml4() + ': 12 Yes - {{Unknown}}</p>'
			+ '<ul><li>&lt;b&gt;first&lt;/b&gt;</li><li>second</li></ul>None', email.getHtmlBody(),
			'The values should be escaped, the lists rendered as HTML, and the unknown placeholders kept');
		Assert.isTrue(email.getPlainTextBody().contains('12 Yes'), 'A plain text version should be generated from the HTML');
		Assert.areEqual(UserInfo.getUserId(), email.getTargetObjectId(), 'The email should be sent to the running user');
	}

	@isTest
	static void plainTextVersionOfTheTemplateTest(){
		PurgeSObjectEmail.templateOverride = new EmailTemplate(Subject = null, HtmlValue = '<p>{{Errors}}</p>', Body = 'Errors:\n{{Errors}}');

		Messaging.SingleEmailMessage email = new PurgeSObjectEmail('Any_Template')
			.put('Errors', new List<String>{'first', 'second'})
			.build('Default subject', 'Default body');

		Assert.areEqual('Default subject', email.getSubject(), 'The default subject should be used when the template has none');
		Assert.areEqual('Errors:\n- first\n- second', email.getPlainTextBody(), 'The text version should render the lists as bullets');
	}

	@isTest
	static void builtInEmailWithoutTemplateTest(){
		Messaging.SingleEmailMessage email = new PurgeSObjectEmail('Template_That_Does_Not_Exist')
			.put('ObjectName', 'Lead')
			.build('Default {{ObjectName}} subject', 'Default body');

		Assert.areEqual('Default {{ObjectName}} subject', email.getSubject(), 'The built-in subject should be sent as is');
		Assert.areEqual('Default body', email.getPlainTextBody(), 'The built-in body should be sent as is');
		Assert.isNull(email.getHtmlBody(), 'The built-in email is plain text');
	}

	@isTest
	static void coreTemplateHasNoUnknownPlaceholderTest(){
		List<EmailTemplate> templates = [SELECT Subject, HtmlValue, Body FROM EmailTemplate WHERE DeveloperName = 'PurgeSObject_Summary'];
		if(templates.isEmpty()){
			//the template isn't deployed: the built-in email is used
			return;
		}
		PurgeSObjectBatch.settingsOverride = new List<PurgeSObjectSetting__mdt>{new PurgeSObjectSetting__mdt(DeveloperName = 'Lead',
			MasterLabel = 'Lead', SObjectApiName__c = 'Lead', Sequence__c = 1, WhereClauseToBeDeleted__c = 'LastName = \'x\'', DryRun__c = true)};
		PurgeSObjectBatch batch = new PurgeSObjectBatch();
		batch.runErrors.add('An error');

		Messaging.SingleEmailMessage email = batch.getErrorSummaryEmail(1, 'First chunk error');

		Assert.isFalse(email.getSubject().contains('{{'), 'Every placeholder of the subject should be known: ' + email.getSubject());
		Assert.isFalse(email.getHtmlBody().contains('{{'), 'Every placeholder of the body should be known: ' + email.getHtmlBody());
		Assert.isTrue(email.getHtmlBody().contains('An error'), 'The errors should be in the email');
	}
}
