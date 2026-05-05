/**
 * Controller for the opportunityPipeline LWC.
 * - Updates Opportunity.StageName + Opportunity.Pipeline_Group__c together
 *   so the path UI and the record stay consistent.
 * - Optionally chains a second update (used when Closed Won auto-advances
 *   into the Billing group).
 * - Mirrors selected stages onto the primary OpportunityContactRole's
 *   Contact (Stage__c, Billing_status__c).
 */
public with sharing class OpportunityPipelineController {

    private static final String CONTACT_STAGE_FIELD   = 'Stage__c';
    private static final String CONTACT_BILLING_FIELD = 'Billing_status__c';

    // Opportunity StageName  →  Contact.Stage__c API name (org-specific)
    private static final Map<String, String> OPP_TO_CONTACT_STAGE = new Map<String, String>{
        'FSS Onboarding'          => '1083265542',  // FSS Onboarding
        'In Program'              => '266117751',   // In Program
        'Paused - Not Delinquent' => '936529426',   // Paused
        'Terminated'              => '1029396323',  // Terminated
        'Terminated - MBG'        => '1077888160',  // Terminated - MBG
        'Closed Won'              => '266117751'    // In Program
    };

    /**
     * Updates StageName + Pipeline_Group__c, optionally chained with a second
     * update for the Closed Won → Billing transition.
     *
     * @param opportunityId          required — record to update
     * @param stageName              required — first StageName to apply
     * @param pipelineGroup          optional — Pipeline_Group__c value (kept consistent)
     * @param advanceToStageName     optional — second StageName applied in same call
     * @param advanceToPipelineGroup optional — second Pipeline_Group__c value
     */
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

            // Return the post-update state so the LWC can refresh its UI
            // immediately, without waiting for the LDS wire to revalidate.
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

    /**
     * Mirrors the new opportunity stage onto the primary contact's
     * Stage__c (mapped) and Billing_status__c (when group = Billing).
     * Bulkified: a single SOQL + at most one DML.
     */
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

    /**
     * Lightweight check — keeps the class compilable in orgs that don't
     * have these custom Contact fields. Cached per transaction.
     */
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

    private static String parseDmlMessage(DmlException e) {
        String msg = e.getMessage();
        Pattern p = Pattern.compile('FIELD_CUSTOM_VALIDATION_EXCEPTION,\\s*(.+?)(?::\\s*\\[|$)');
        Matcher m = p.matcher(msg);
        return m.find() ? m.group(1).trim() : msg;
    }
}
