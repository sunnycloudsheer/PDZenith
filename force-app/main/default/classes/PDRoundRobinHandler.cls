public with sharing class PDRoundRobinHandler {

    private static final String PD_PROFILE_NAME = 'Program Director';

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

    @InvocableMethod(
        label='Get PD Assignment (Round Robin or Sticky)'
        description='Determines which PD should handle this Opportunity. Uses sticky if already assigned, otherwise weighted round-robin.'
        category='Scheduling'
    )
    public static List<PDResult> getAssignedPD(List<PDRequest> requests) {
        List<PDResult> results = new List<PDResult>();

        for (PDRequest req : requests) {
            PDResult res = new PDResult();
            try {
                List<Opportunity> oppList = [
                    SELECT Id, Program_Director__c
                    FROM Opportunity
                    WHERE Id = :req.opportunityId LIMIT 1
                ];
                if (oppList.isEmpty()) {
                    throw new AuraHandledException('Opportunity not found: ' + req.opportunityId);
                }
                Opportunity opp = oppList[0];
                Boolean followUp = (req.isFollowUp != null && req.isFollowUp);

                Id selectedResourceId;
                Boolean isSticky = false;

                if (opp.Program_Director__c != null) {
                    List<User> pdUser = [
                        SELECT Id FROM User
                        WHERE Id = :opp.Program_Director__c
                        AND Profile.Name = :PD_PROFILE_NAME
                        AND IsActive = true LIMIT 1
                    ];
                    if (!pdUser.isEmpty()) {
                        List<ServiceResource> stickyCheck = [
                            SELECT Id FROM ServiceResource
                            WHERE RelatedRecordId = :opp.Program_Director__c
                            AND IsActive = true LIMIT 1
                        ];
                        if (!stickyCheck.isEmpty()) {
                            selectedResourceId = stickyCheck[0].Id;
                            isSticky = true;
                        }
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
        } catch (Exception e) { }

        ServiceTerritoryMember bestStm = null;
        Id matchedWorkTypeId = null;

        for (ServiceTerritoryMember stm : stmList) {
            if (territoryToWorkType.containsKey(stm.ServiceTerritoryId)
                && (stm.ServiceTerritory.OperatingHoursId != null || stm.OperatingHoursId != null)) {
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
                if (stm.ServiceTerritory.OperatingHoursId != null || stm.OperatingHoursId != null) {
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
            } catch (Exception e) { }
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
