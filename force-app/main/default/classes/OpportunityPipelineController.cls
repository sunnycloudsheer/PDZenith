// Controller for the opportunityPipeline LWC: updates Stage + Pipeline_Group together and mirrors selected stages onto the primary Contact.
public with sharing class OpportunityPipelineController {

    private static final String CONTACT_STAGE_FIELD   = 'Stage__c';
    private static final String CONTACT_BILLING_FIELD = 'Billing_status__c';

    // Opportunity StageName → Contact.Stage__c picklist API value (org-specific).
    private static final Map<String, String> OPP_TO_CONTACT_STAGE = new Map<String, String>{
        'FSS Onboarding'          => '1083265542',
        'In Program'              => '266117751',
        'Paused - Not Delinquent' => '936529426',
        'Terminated'              => '1029396323',
        'Terminated - MBG'        => '1077888160',
        'Closed Won'              => '266117751'
    };

    // Updates Stage + Pipeline_Group, optionally chained for Closed Won → Billing transition.
    @AuraEnabled
    public static Opportunity updateOpportunityStage(
        Id opportunityId,
        String stageName,
        String pipelineGroup,
        String advanceToStageName,
        String advanceToPipelineGroup
    ) {
        if (opportunityId == null || String.isBlank(stageName)) {
            throw new AuraHandledException('Opportunity Id and Stage are required.');
        }

        try {
            update new List<Opportunity>{ buildOpp(opportunityId, stageName, pipelineGroup) };

            String finalStage = stageName;
            String finalGroup = pipelineGroup;

            if (String.isNotBlank(advanceToStageName)) {
                update new List<Opportunity>{
                    buildOpp(opportunityId, advanceToStageName, advanceToPipelineGroup)
                };
                finalStage = advanceToStageName;
                finalGroup = advanceToPipelineGroup;
            }

            syncPrimaryContact(opportunityId, finalStage, finalGroup);

            return [
                SELECT Id, StageName, Pipeline_Group__c
                FROM Opportunity
                WHERE Id = :opportunityId
                LIMIT 1
            ];

        } catch (DmlException e) {
            throw new AuraHandledException(parseDmlMessage(e));
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static Opportunity buildOpp(Id oppId, String stage, String pipelineGroup) {
        Opportunity o = new Opportunity(Id = oppId, StageName = stage);
        if (String.isNotBlank(pipelineGroup)) o.Pipeline_Group__c = pipelineGroup;
        return o;
    }

    // Mirrors the new Stage onto the primary Contact's Stage__c and Billing_status__c (when group=Billing).
    @TestVisible
    private static void syncPrimaryContact(Id opportunityId, String stageName, String pipelineGroup) {
        Id contactId = primaryContactId(opportunityId);
        if (contactId == null) return;

        Contact c = new Contact(Id = contactId);
        Boolean dirty = false;

        if (OPP_TO_CONTACT_STAGE.containsKey(stageName) && fieldExists('Contact', CONTACT_STAGE_FIELD)) {
            c.put(CONTACT_STAGE_FIELD, OPP_TO_CONTACT_STAGE.get(stageName));
            dirty = true;
        }

        if (pipelineGroup == 'Billing' && fieldExists('Contact', CONTACT_BILLING_FIELD)) {
            c.put(CONTACT_BILLING_FIELD, stageName);
            dirty = true;
        }

        if (dirty) update new List<Contact>{ c };
    }

    private static Id primaryContactId(Id opportunityId) {
        for (OpportunityContactRole r : [
            SELECT ContactId
            FROM OpportunityContactRole
            WHERE OpportunityId = :opportunityId
            ORDER BY IsPrimary DESC
            LIMIT 1
        ]) {
            return r.ContactId;
        }
        return null;
    }

    // Field-existence check cached per transaction; keeps class compilable in orgs missing the custom fields.
    private static Map<String, Boolean> fieldExistsCache = new Map<String, Boolean>();
    private static Boolean fieldExists(String objectName, String fieldName) {
        String key = objectName + '.' + fieldName;
        Boolean cached = fieldExistsCache.get(key);
        if (cached != null) return cached;
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
        Boolean exists = t != null && t.getDescribe().fields.getMap().containsKey(fieldName);
        fieldExistsCache.put(key, exists);
        return exists;
    }

    // Extracts the user-friendly message from a DML validation-rule exception.
    private static String parseDmlMessage(DmlException e) {
        String msg = e.getMessage();
        Pattern p = Pattern.compile('FIELD_CUSTOM_VALIDATION_EXCEPTION,\\s*(.+?)(?::\\s*\\[|$)');
        Matcher m = p.matcher(msg);
        return m.find() ? m.group(1).trim() : msg;
    }
}
