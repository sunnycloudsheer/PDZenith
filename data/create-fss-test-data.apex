// ═══════════════════════════════════════════════════════════
// FSS Test Data Setup
// Creates 3 FSS Onboarding users with ServiceResources,
// ServiceTerritory, and ServiceTerritoryMembers
// ═══════════════════════════════════════════════════════════

// 1. Get the FSS Onboarding profile
Profile fssProfile = [SELECT Id FROM Profile WHERE Name = 'FSS Onboarding' LIMIT 1];

// 2. Create 3 FSS Users
List<User> fssUsers = new List<User>();
List<Map<String, String>> userData = new List<Map<String, String>>{
    new Map<String, String>{
        'FirstName' => 'Sarah', 'LastName' => 'Johnson',
        'Email' => 'sarah.johnson@zenithprepacademy.com',
        'Alias' => 'sjohn'
    },
    new Map<String, String>{
        'FirstName' => 'Michael', 'LastName' => 'Chen',
        'Email' => 'michael.chen@zenithprepacademy.com',
        'Alias' => 'mchen'
    },
    new Map<String, String>{
        'FirstName' => 'Emily', 'LastName' => 'Rodriguez',
        'Email' => 'emily.rodriguez@zenithprepacademy.com',
        'Alias' => 'erodri'
    }
};

for (Integer i = 0; i < userData.size(); i++) {
    Map<String, String> ud = userData[i];
    fssUsers.add(new User(
        FirstName       = ud.get('FirstName'),
        LastName        = ud.get('LastName'),
        Email           = ud.get('Email'),
        Username        = 'fss' + (i+1) + '@zenithprepacademy.com.dev2',
        Alias           = ud.get('Alias'),
        ProfileId       = fssProfile.Id,
        TimeZoneSidKey  = 'America/New_York',
        LocaleSidKey    = 'en_US',
        EmailEncodingKey = 'UTF-8',
        LanguageLocaleKey = 'en_US'
    ));
}
insert fssUsers;
System.debug('Created FSS Users: ' + fssUsers.size());

// 3. Create ServiceResources for each FSS User
List<ServiceResource> srList = new List<ServiceResource>();
for (User u : fssUsers) {
    srList.add(new ServiceResource(
        Name            = u.FirstName + ' ' + u.LastName + ' - Service Resource',
        RelatedRecordId = u.Id,
        IsActive        = true
    ));
}
insert srList;
System.debug('Created Service Resources: ' + srList.size());

// 4. Set Weight and Appointment Count for round-robin
srList[0].Weight__c = 1.0; srList[0].Appointment_Count__c = 0;
srList[1].Weight__c = 1.0; srList[1].Appointment_Count__c = 0;
srList[2].Weight__c = 1.0; srList[2].Appointment_Count__c = 0;
update srList;

// 5. Get or Create Operating Hours
OperatingHours oh;
List<OperatingHours> existingOH = [SELECT Id FROM OperatingHours LIMIT 1];
if (!existingOH.isEmpty()) {
    oh = existingOH[0];
    System.debug('Using existing Operating Hours: ' + oh.Id);
} else {
    oh = new OperatingHours(Name = 'FSS Operating Hours', TimeZone = 'America/New_York');
    insert oh;
    List<TimeSlot> slots = new List<TimeSlot>();
    for (String day : new List<String>{'Monday','Tuesday','Wednesday','Thursday','Friday'}) {
        slots.add(new TimeSlot(
            OperatingHoursId = oh.Id, DayOfWeek = day,
            StartTime = Time.newInstance(9,0,0,0),
            EndTime = Time.newInstance(17,0,0,0)
        ));
    }
    insert slots;
    System.debug('Created Operating Hours with TimeSlots');
}

// 6. Create ServiceTerritory for FSS
ServiceTerritory fssTerritory = new ServiceTerritory(
    Name             = 'FSS Territory',
    IsActive         = true,
    OperatingHoursId = oh.Id
);
insert fssTerritory;
System.debug('Created FSS Territory: ' + fssTerritory.Id);

// 7. Create ServiceTerritoryMembers
List<ServiceTerritoryMember> stmList = new List<ServiceTerritoryMember>();
for (ServiceResource sr : srList) {
    stmList.add(new ServiceTerritoryMember(
        ServiceTerritoryId = fssTerritory.Id,
        ServiceResourceId  = sr.Id,
        EffectiveStartDate = Date.today().addDays(-30),
        TerritoryType      = 'P'
    ));
}
insert stmList;
System.debug('Created Territory Members: ' + stmList.size());

// 8. Summary
System.debug('═══════════════════════════════════════');
System.debug('FSS TEST DATA CREATED SUCCESSFULLY');
System.debug('═══════════════════════════════════════');
System.debug('Users:');
for (User u : fssUsers) {
    System.debug('  ' + u.FirstName + ' ' + u.LastName + ' (' + u.Username + ')');
}
System.debug('Service Resources: ' + srList.size());
System.debug('Territory: FSS Territory (' + fssTerritory.Id + ')');
System.debug('Territory Members: ' + stmList.size());
System.debug('All weights: 1.0, All counts: 0');
System.debug('═══════════════════════════════════════');
