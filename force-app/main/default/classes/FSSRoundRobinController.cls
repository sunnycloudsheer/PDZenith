public without sharing class FSSRoundRobinController {

    private static final String FSS_ROLE = 'Family Success Specialist';

    public class FSSResult {
        @InvocableVariable(label='FSS User Id')
        public Id fssUserId;

        @InvocableVariable(label='FSS ServiceResource Id')
        public Id serviceResourceId;

        @InvocableVariable(label='FSS Name')
        public String fssName;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(
        label='Get Next FSS (Round Robin)'
        description='Selects the next Family Success Specialist via weighted round-robin based on Appointment_Count__c / Weight__c.'
        category='Scheduling'
    )
    public static List<FSSResult> getNextFSS(List<List<String>> dummyInput) {
        List<FSSResult> results = new List<FSSResult>();
        FSSResult res = new FSSResult();

        try {
            List<ServiceResource> fssResources = [
                SELECT Id, Name, RelatedRecordId, Appointment_Count__c, Weight__c
                FROM ServiceResource
                WHERE Role__c = :FSS_ROLE
                AND IsActive = true
                AND RelatedRecordId != null
                ORDER BY CreatedDate ASC
            ];
            if (fssResources.isEmpty()) {
                throw new AuraHandledException('No active Family Success Specialist Service Resources found.');
            }

            Set<Id> fssUserIds = new Set<Id>();
            for (ServiceResource sr : fssResources) {
                fssUserIds.add(sr.RelatedRecordId);
            }

            Set<Id> activeUserIds = new Set<Id>();
            for (User u : [
                SELECT Id FROM User
                WHERE Id IN :fssUserIds AND IsActive = true
            ]) {
                activeUserIds.add(u.Id);
            }

            Id bestId = null;
            Decimal bestLoad = null;
            ServiceResource bestSR = null;

            for (ServiceResource sr : fssResources) {
                if (!activeUserIds.contains(sr.RelatedRecordId)) continue;
                Decimal count  = (sr.Appointment_Count__c != null) ? sr.Appointment_Count__c : 0;
                Decimal weight = (sr.Weight__c != null && sr.Weight__c > 0) ? sr.Weight__c : 1.0;
                Decimal load   = count / weight;
                if (bestLoad == null || load < bestLoad) {
                    bestLoad = load;
                    bestId   = sr.Id;
                    bestSR   = sr;
                }
            }

            if (bestSR == null) {
                throw new AuraHandledException('No eligible FSS found with active User.');
            }

            bestSR.Appointment_Count__c = (bestSR.Appointment_Count__c != null)
                ? bestSR.Appointment_Count__c + 1 : 1;
            update bestSR;

            res.serviceResourceId = bestSR.Id;
            res.fssUserId         = bestSR.RelatedRecordId;
            res.fssName           = bestSR.Name;
            res.success           = true;

        } catch (Exception e) {
            res.success      = false;
            res.errorMessage = e.getMessage();
        }

        results.add(res);
        return results;
    }
}
