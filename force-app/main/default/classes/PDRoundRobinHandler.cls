public with sharing class PDRoundRobinHandler {

    private static final String PD_PROFILE_NAME = System.Label.PD_Profile_Name;

    public class PDRequest {
        @InvocableVariable(required=true label='Opportunity Id')
        public Id opportunityId;

        @InvocableVariable(required=true label='Is Follow-up Call')
        public Boolean isFollowUp;
    }

    public class PDResult {
        @InvocableVariable(label='Selected ServiceResource Id')
        public Id serviceResourceId;

        @InvocableVariable(label='Selected ServiceTerritory Id')
        public Id serviceTerritoryId;

        @InvocableVariable(label='WorkType Id')
        public Id workTypeId;

        @InvocableVariable(label='PD Name')
        public String pdName;

        @InvocableVariable(label='PD User Id')
        public Id pdUserId;

        @InvocableVariable(label='Is Sticky Assignment')
        public Boolean isSticky;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    private class DiscoveredPD {
        Id serviceResourceId;
        String pdName;
        Id pdUserId;
        Id serviceTerritoryId;
        Id operatingHoursId;
        Id workTypeId;
        Boolean isSticky = false;
    }

    // Returns the PD assignment per Opportunity, using sticky if set, otherwise weighted round-robin.
    @InvocableMethod(
        label='Get PD Assignment (Round Robin or Sticky)'
        description='Determines which PD should handle this Opportunity. Uses sticky if already assigned, otherwise weighted round-robin.'
        category='Scheduling'
    )
    public static List<PDResult> getAssignedPD(List<PDRequest> requests) {
        List<PDResult> results = new List<PDResult>();

        Set<Id> oppIds = new Set<Id>();
        for (PDRequest req : requests) {
            oppIds.add(req.opportunityId);
        }

        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>([
            SELECT Id, Program_Director__c
            FROM Opportunity
            WHERE Id IN :oppIds
        ]);

        Set<Id> stickyPDUserIds = new Set<Id>();
        for (Opportunity opp : oppMap.values()) {
            if (opp.Program_Director__c != null) {
                stickyPDUserIds.add(opp.Program_Director__c);
            }
        }

        Set<Id> validPDUserIds = new Set<Id>();
        if (!stickyPDUserIds.isEmpty()) {
            for (User u : [
                SELECT Id FROM User
                WHERE Id IN :stickyPDUserIds
                AND Profile.Name = :PD_PROFILE_NAME
                AND IsActive = true
            ]) {
                validPDUserIds.add(u.Id);
            }
        }

        Map<Id, Id> pdUserToResourceId = new Map<Id, Id>();
        if (!validPDUserIds.isEmpty()) {
            for (ServiceResource sr : [
                SELECT Id, RelatedRecordId FROM ServiceResource
                WHERE RelatedRecordId IN :validPDUserIds AND IsActive = true
            ]) {
                pdUserToResourceId.put(sr.RelatedRecordId, sr.Id);
            }
        }

        for (PDRequest req : requests) {
            PDResult res = new PDResult();
            try {
                Opportunity opp = oppMap.get(req.opportunityId);
                if (opp == null) {
                    throw new AuraHandledException('Opportunity not found: ' + req.opportunityId);
                }
                Boolean followUp = (req.isFollowUp != null && req.isFollowUp);

                Id selectedResourceId;
                Boolean isSticky = false;

                if (opp.Program_Director__c != null
                    && validPDUserIds.contains(opp.Program_Director__c)) {
                    Id stickyResId = pdUserToResourceId.get(opp.Program_Director__c);
                    if (stickyResId != null) {
                        selectedResourceId = stickyResId;
                        isSticky = true;
                    }
                }

                if (selectedResourceId == null) {
                    selectedResourceId = selectByWeightedRoundRobin();
                }

                DiscoveredPD discovered = discoverFromResource(selectedResourceId, followUp);
                discovered.isSticky = isSticky;

                res.serviceResourceId  = discovered.serviceResourceId;
                res.serviceTerritoryId = discovered.serviceTerritoryId;
                res.workTypeId         = discovered.workTypeId;
                res.pdName             = discovered.pdName;
                res.pdUserId           = discovered.pdUserId;
                res.isSticky           = discovered.isSticky;
                res.success            = true;

            } catch (Exception e) {
                res.success      = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    // Resolves territory, work type, and operating hours from a chosen ServiceResource.
    private static DiscoveredPD discoverFromResource(Id resourceId, Boolean isFollowUp) {
        DiscoveredPD cfg = new DiscoveredPD();
        cfg.serviceResourceId = resourceId;

        List<ServiceResource> srList = [
            SELECT Id, Name, RelatedRecordId FROM ServiceResource
            WHERE Id = :resourceId AND IsActive = true LIMIT 1
        ];
        if (srList.isEmpty()) {
            throw new AuraHandledException('Selected PD Service Resource is not active.');
        }
        ServiceResource sr = srList[0];
        cfg.pdName = sr.Name;

        if (sr.RelatedRecordId == null) {
            throw new AuraHandledException('Service Resource "' + sr.Name + '" has no related User.');
        }
        List<User> userCheck = [
            SELECT Id FROM User
            WHERE Id = :sr.RelatedRecordId
            AND Profile.Name = :PD_PROFILE_NAME
            AND IsActive = true LIMIT 1
        ];
        if (userCheck.isEmpty()) {
            throw new AuraHandledException(
                'The related User for "' + sr.Name + '" does not have the Program Director profile or is inactive.'
            );
        }
        cfg.pdUserId = sr.RelatedRecordId;

        Date today = Date.today();
        List<ServiceTerritoryMember> stmList = [
            SELECT ServiceTerritoryId, OperatingHoursId,
                   ServiceTerritory.OperatingHoursId, ServiceTerritory.IsActive, ServiceTerritory.Name
            FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :sr.Id
            AND EffectiveStartDate <= :today
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
            AND ServiceTerritory.IsActive = true
            ORDER BY CreatedDate DESC
        ];
        if (stmList.isEmpty()) {
            throw new AuraHandledException(
                'No active Service Territory found for PD "' + sr.Name
                + '". Please assign this PD to a Service Territory with valid membership dates.'
            );
        }

        Integer targetDuration = isFollowUp ? 30 : 60;

        Set<Id> candidateTerritoryIds = new Set<Id>();
        Map<Id, ServiceTerritoryMember> stmByTerritoryId = new Map<Id, ServiceTerritoryMember>();
        for (ServiceTerritoryMember stm : stmList) {
            candidateTerritoryIds.add(stm.ServiceTerritoryId);
            if (!stmByTerritoryId.containsKey(stm.ServiceTerritoryId)) {
                stmByTerritoryId.put(stm.ServiceTerritoryId, stm);
            }
        }

        Map<Id, Id> territoryToWorkType = new Map<Id, Id>();
        try {
            for (ServiceTerritoryWorkType stwt : [
                SELECT ServiceTerritoryId, WorkTypeId, WorkType.DurationInMinutes
                FROM ServiceTerritoryWorkType
                WHERE ServiceTerritoryId IN :candidateTerritoryIds
            ]) {
                if (stwt.WorkType.DurationInMinutes == targetDuration) {
                    territoryToWorkType.put(stwt.ServiceTerritoryId, stwt.WorkTypeId);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'PDRoundRobinHandler.discoverFromResource: territoryToWorkType build skipped: ' + e.getMessage());
        }

        Set<Id> allOHIds = new Set<Id>();
        for (ServiceTerritoryMember stm : stmList) {
            if (stm.ServiceTerritory.OperatingHoursId != null) allOHIds.add(stm.ServiceTerritory.OperatingHoursId);
            if (stm.OperatingHoursId != null) allOHIds.add(stm.OperatingHoursId);
        }
        Set<Id> validOHIds = new Set<Id>();
        if (!allOHIds.isEmpty()) {
            for (TimeSlot ts : [
                SELECT OperatingHoursId FROM TimeSlot
                WHERE OperatingHoursId IN :allOHIds LIMIT 200
            ]) {
                validOHIds.add(ts.OperatingHoursId);
            }
        }

        ServiceTerritoryMember bestStm = null;
        Id matchedWorkTypeId = null;

        for (ServiceTerritoryMember stm : stmList) {
            if (territoryToWorkType.containsKey(stm.ServiceTerritoryId)
                && hasValidOH(stm, validOHIds)) {
                bestStm = stm;
                matchedWorkTypeId = territoryToWorkType.get(stm.ServiceTerritoryId);
                break;
            }
        }

        if (bestStm == null) {
            for (ServiceTerritoryMember stm : stmList) {
                if (territoryToWorkType.containsKey(stm.ServiceTerritoryId)) {
                    bestStm = stm;
                    matchedWorkTypeId = territoryToWorkType.get(stm.ServiceTerritoryId);
                    break;
                }
            }
        }

        if (bestStm == null) {
            for (ServiceTerritoryMember stm : stmList) {
                if (hasValidOH(stm, validOHIds)) {
                    bestStm = stm;
                    break;
                }
            }
        }

        if (bestStm == null) {
            bestStm = stmList[0];
        }

        cfg.serviceTerritoryId = bestStm.ServiceTerritoryId;

        if (bestStm.ServiceTerritory.OperatingHoursId != null) {
            cfg.operatingHoursId = bestStm.ServiceTerritory.OperatingHoursId;
        } else if (bestStm.OperatingHoursId != null) {
            cfg.operatingHoursId = bestStm.OperatingHoursId;
        }

        if (matchedWorkTypeId != null) {
            cfg.workTypeId = matchedWorkTypeId;
        } else {
            cfg.workTypeId = discoverWorkType(isFollowUp, cfg.serviceTerritoryId, cfg.operatingHoursId);
        }
        if (cfg.workTypeId == null) {
            throw new AuraHandledException(
                'No Work Type found for territory "' + bestStm.ServiceTerritory.Name
                + '". Please create a Work Type and link it to the Service Territory or its Operating Hours.'
            );
        }

        return cfg;
    }

    // True when the territory member has an operating hours record with valid TimeSlots.
    private static Boolean hasValidOH(ServiceTerritoryMember stm, Set<Id> validOHIds) {
        return (stm.ServiceTerritory.OperatingHoursId != null && validOHIds.contains(stm.ServiceTerritory.OperatingHoursId))
            || (stm.OperatingHoursId != null && validOHIds.contains(stm.OperatingHoursId));
    }

    // Finds the most appropriate WorkType for the given duration, territory, and operating hours.
    private static Id discoverWorkType(Boolean isFollowUp, Id territoryId, Id operatingHoursId) {
        String preferredName = isFollowUp ? 'PD Follow-up - 30min' : 'PD SOM Meeting - 1hr';

        List<WorkType> exactMatch = [SELECT Id FROM WorkType WHERE Name = :preferredName LIMIT 1];
        if (!exactMatch.isEmpty()) return exactMatch[0].Id;

        if (territoryId != null) {
            try {
                List<ServiceTerritoryWorkType> stwts = [
                    SELECT WorkTypeId, WorkType.DurationInMinutes
                    FROM ServiceTerritoryWorkType
                    WHERE ServiceTerritoryId = :territoryId
                    ORDER BY WorkType.DurationInMinutes ASC
                ];
                if (!stwts.isEmpty()) {
                    return isFollowUp ? stwts[0].WorkTypeId : stwts[stwts.size() - 1].WorkTypeId;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'PDRoundRobinHandler.discoverWorkType: territory work-type lookup skipped: ' + e.getMessage());
            }
        }

        if (operatingHoursId != null) {
            List<WorkType> wtByOH = [
                SELECT Id, DurationInMinutes FROM WorkType
                WHERE OperatingHoursId = :operatingHoursId
                ORDER BY DurationInMinutes DESC
            ];
            if (!wtByOH.isEmpty()) {
                return isFollowUp ? wtByOH[wtByOH.size() - 1].Id : wtByOH[0].Id;
            }
        }

        String likePattern = isFollowUp ? '%Follow%' : '%SOM%';
        List<WorkType> patternMatch = [
            SELECT Id FROM WorkType WHERE Name LIKE :likePattern
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (!patternMatch.isEmpty()) return patternMatch[0].Id;

        List<WorkType> pdPattern = [
            SELECT Id FROM WorkType WHERE Name LIKE '%PD%'
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (!pdPattern.isEmpty()) return pdPattern[0].Id;

        List<WorkType> anyWT = [SELECT Id FROM WorkType ORDER BY CreatedDate DESC LIMIT 1];
        if (!anyWT.isEmpty()) return anyWT[0].Id;

        return null;
    }

    // Picks the active PD ServiceResource with the lowest weight-adjusted appointment load.
    private static Id selectByWeightedRoundRobin() {
        Set<Id> pdUserIds = new Set<Id>();
        for (User u : [
            SELECT Id FROM User
            WHERE Profile.Name = :PD_PROFILE_NAME AND IsActive = true
        ]) {
            pdUserIds.add(u.Id);
        }
        if (pdUserIds.isEmpty()) {
            throw new AuraHandledException('No active users found with the Program Director profile.');
        }

        List<ServiceResource> pdResources = [
            SELECT Id, Appointment_Count__c, Weight__c, RelatedRecordId
            FROM ServiceResource
            WHERE RelatedRecordId IN :pdUserIds AND IsActive = true
            ORDER BY CreatedDate ASC
        ];
        if (pdResources.isEmpty()) {
            throw new AuraHandledException('No active Service Resources found for Program Director users.');
        }

        Set<Id> allSrIds = new Set<Id>();
        for (ServiceResource sr : pdResources) allSrIds.add(sr.Id);

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

        List<ServiceResource> validResources = new List<ServiceResource>();
        for (ServiceResource sr : pdResources) {
            if (resourcesWithTerritory.contains(sr.Id)) {
                validResources.add(sr);
            }
        }
        if (validResources.isEmpty()) {
            throw new AuraHandledException(
                'No fully configured PD Service Resources found. Each PD needs: active User with Program Director profile, active Service Resource, and active Service Territory membership.'
            );
        }

        Id      bestId   = null;
        Decimal bestLoad = null;
        for (ServiceResource sr : validResources) {
            Decimal count = (sr.Appointment_Count__c != null) ? sr.Appointment_Count__c : 0;
            Decimal weight = (sr.Weight__c != null && sr.Weight__c > 0) ? sr.Weight__c : 1.0;
            Decimal effectiveLoad = count / weight;
            if (bestLoad == null || effectiveLoad < bestLoad) {
                bestLoad = effectiveLoad;
                bestId   = sr.Id;
            }
        }
        return bestId;
    }
}