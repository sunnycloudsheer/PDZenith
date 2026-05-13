public without sharing class FSSRoundRobinController {

    private static final String FSS_PROFILE_NAME = 'FSS Onboarding';

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
        description='Selects the next Family Success Specialist via weighted round-robin. Finds users with FSS Onboarding profile, their active ServiceResources with active territory memberships.'
        category='Scheduling'
    )
    public static List<FSSResult> getNextFSS(List<List<String>> dummyInput) {
        List<FSSResult> results = new List<FSSResult>();
        FSSResult res = new FSSResult();

        try {
            Set<Id> fssUserIds = new Set<Id>();
            for (User u : [
                SELECT Id FROM User
                WHERE Profile.Name = :FSS_PROFILE_NAME AND IsActive = true
            ]) {
                fssUserIds.add(u.Id);
            }
            if (fssUserIds.isEmpty()) {
                throw new AuraHandledException('No active users found with the FSS Onboarding profile.');
            }

            List<ServiceResource> fssResources = [
                SELECT Id, Name, RelatedRecordId, Appointment_Count__c, Weight__c
                FROM ServiceResource
                WHERE RelatedRecordId IN :fssUserIds AND IsActive = true
                ORDER BY CreatedDate ASC
            ];
            if (fssResources.isEmpty()) {
                throw new AuraHandledException('No active Service Resources found for FSS Onboarding users.');
            }

            Set<Id> allSrIds = new Set<Id>();
            for (ServiceResource sr : fssResources) {
                allSrIds.add(sr.Id);
            }

            Date today = Date.today();
            Set<Id> resourcesWithTerritory = new Set<Id>();
            for (ServiceTerritoryMember stm : [
                SELECT ServiceResourceId FROM ServiceTerritoryMember
                WHERE ServiceResourceId IN :allSrIds
                AND EffectiveStartDate <= :today
                AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
                AND ServiceTerritory.IsActive = true
            ]) {
                resourcesWithTerritory.add(stm.ServiceResourceId);
            }

            Id bestId = null;
            Decimal bestLoad = null;
            ServiceResource bestSR = null;

            for (ServiceResource sr : fssResources) {
                if (!resourcesWithTerritory.contains(sr.Id)) continue;
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
                throw new AuraHandledException(
                    'No fully configured FSS found. Each FSS needs: active User with FSS Onboarding profile, active Service Resource, and active Service Territory membership.'
                );
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