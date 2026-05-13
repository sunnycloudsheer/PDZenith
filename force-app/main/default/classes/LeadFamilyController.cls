// Controller for the leadStudentManager and leadParentGuardianManager LWCs — manages up to 3 students and 2 adults stored in Lead fields.
public with sharing class LeadFamilyController {

    public static final Integer MAX_STUDENTS = 3;
    private static final Set<String> ALLOWED_ADULT_TYPES = new Set<String>{ 'Parent', 'Guardian' };
    private static final String ROLE_PRIMARY = 'Primary';
    private static final String ROLE_SECOND  = 'Second';

    public class StudentList {
        @AuraEnabled public Id leadId;
        @AuraEnabled public List<StudentDTO> students;
        @AuraEnabled public Integer maxAllowed;
    }

    public class ParentList {
        @AuraEnabled public Id leadId;
        @AuraEnabled public AdultDTO primary;
        @AuraEnabled public AdultDTO second;
    }

    public class StudentDTO {
        @AuraEnabled public Integer slot;
        @AuraEnabled public String firstName;
        @AuraEnabled public String lastName;
        @AuraEnabled public String fullName;
        @AuraEnabled public String email;
        @AuraEnabled public String grade;
        @AuraEnabled public Boolean populated;
        @AuraEnabled public String studentId;
    }

    public class AdultDTO {
        @AuraEnabled public String role;
        @AuraEnabled public String type;
        @AuraEnabled public String firstName;
        @AuraEnabled public String lastName;
        @AuraEnabled public String fullName;
        @AuraEnabled public String email;
        @AuraEnabled public String phone;
        @AuraEnabled public Boolean populated;
        @AuraEnabled public String parentId;
    }

    // Returns the Lead's student roster + the cap derived from No_of_Student_Enrolling_Today__c.
    @AuraEnabled(cacheable=true)
    public static StudentList getStudents(Id leadId) {
        Lead ld = queryLead(leadId);
        StudentList out = new StudentList();
        out.leadId = ld.Id;
        out.maxAllowed = parseMaxStudents(ld.No_of_Student_Enrolling_Today__c);
        out.students = new List<StudentDTO>{
            buildStudentFromCombined(1, ld.Student_Name__c,    ld.Student_Email__c,   ld.Student_s_Current_Grade__c, ld.Student_ID_1__c),
            buildStudentFromCombined(2, ld.Student_2_Name__c,  ld.Student_2_Email__c, ld.Student_2_Grade__c,         ld.Student_ID_2__c),
            buildStudentFromCombined(3, ld.Student_3_Name__c,  ld.Student_3_Email__c, ld.Student_3_Grade__c,         ld.Student_ID_3__c)
        };
        return out;
    }

    // Creates / updates a student row, enforces the cap, and stamps a Student ID on first save.
    @AuraEnabled
    public static StudentList saveStudent(Id leadId, Integer slot, String firstName, String lastName, String email, String grade) {
        validateSlot(slot);
        String fn = safeTrim(firstName);
        String ln = safeTrim(lastName);
        String em = safeTrim(email);
        String gr = safeTrim(grade);

        if (String.isBlank(fn)) throw buildError('First Name is required.');
        if (String.isBlank(ln)) throw buildError('Last Name is required.');
        if (String.isNotBlank(em) && !isValidEmail(em)) throw buildError('Please enter a valid email.');

        Lead ld = queryLead(leadId);
        Integer cap = parseMaxStudents(ld.No_of_Student_Enrolling_Today__c);
        Boolean creatingNewEntry = !isSlotPopulated(ld, slot);
        if (creatingNewEntry) {
            if (cap == 0) {
                throw buildError('Set "# of Students Enrolling Today" on the Lead before adding students.');
            }
            if (slot > cap) {
                throw buildError('Only ' + cap + ' student(s) allowed for this Lead.');
            }
            if (countPopulatedStudents(ld) >= cap) {
                throw buildError('Student limit reached (' + cap + ').');
            }
        }
        applyStudentToLead(ld, slot, fn, ln, em, gr);
        // Generated once per slot; never regenerated, so the ID survives edits.
        if (String.isBlank(getStudentIdForSlot(ld, slot))) {
            setStudentIdForSlot(ld, slot, generateUniqueId('S'));
        }
        update ld;
        return getStudents(leadId);
    }

    // Clears the named student slot (Student ID is intentionally preserved is part of slot, but slot is cleared).
    @AuraEnabled
    public static StudentList deleteStudent(Id leadId, Integer slot) {
        validateSlot(slot);
        Lead ld = queryLead(leadId);
        applyStudentToLead(ld, slot, null, null, null, null);
        update ld;
        return getStudents(leadId);
    }

    // Returns the Primary parent (mirrored from Lead.FirstName/etc) and Second adult.
    @AuraEnabled(cacheable=true)
    public static ParentList getParents(Id leadId) {
        Lead ld = queryLead(leadId);
        ParentList out = new ParentList();
        out.leadId = ld.Id;
        out.primary = buildPrimaryAdult(ld);
        out.second  = buildSecondAdult(ld);
        return out;
    }

    // Saves the Primary or Second adult; Primary writes to Lead.FirstName/etc (the source for Parent_1_* sync).
    @AuraEnabled
    public static ParentList saveParent(Id leadId, String role, String adultType, String firstName, String lastName, String email, String phone) {
        String rl = safeTrim(role);
        String type = safeTrim(adultType);
        String fn = safeTrim(firstName);
        String ln = safeTrim(lastName);
        String em = safeTrim(email);
        String ph = safeTrim(phone);

        if (rl != ROLE_PRIMARY && rl != ROLE_SECOND) {
            throw buildError('Role must be Primary or Second.');
        }
        if (String.isBlank(fn)) throw buildError('First Name is required.');
        if (String.isBlank(ln)) throw buildError('Last Name is required.');
        if (String.isNotBlank(em) && !isValidEmail(em)) throw buildError('Please enter a valid email.');

        String combined = combineName(fn, ln);
        Lead ld = queryLead(leadId);

        if (rl == ROLE_PRIMARY) {
            // Primary is always a Parent; Parent_1_* fields are auto-synced from these source fields.
            ld.FirstName = fn;
            ld.LastName  = ln;
            ld.Email     = em;
            ld.Phone     = ph;
            if (String.isBlank(ld.Parent_1_ID__c)) {
                ld.Parent_1_ID__c = generateUniqueId('P');
            }
        } else {
            if (String.isBlank(type) || !ALLOWED_ADULT_TYPES.contains(type)) {
                throw buildError('Type must be Parent or Guardian.');
            }
            ld.Parent_2_Name_First_Last__c = combined;
            ld.Parent_2_Email__c = em;
            ld.Parent_2_Phone__c = ph;
            ld.Second_Adult_Type__c = type;
            if (String.isBlank(ld.Parent_2_ID__c)) {
                ld.Parent_2_ID__c = generateUniqueId('P');
            }
        }
        update ld;
        return getParents(leadId);
    }

    // Idempotent: stamps Parent 1 ID on first LWC load if missing.
    @AuraEnabled
    public static ParentList ensurePrimaryParentId(Id leadId) {
        Lead ld = queryLead(leadId);
        if (String.isBlank(ld.Parent_1_ID__c)) {
            ld.Parent_1_ID__c = generateUniqueId('P');
            update ld;
            ld = queryLead(leadId);
        }
        ParentList out = new ParentList();
        out.leadId = ld.Id;
        out.primary = buildPrimaryAdult(ld);
        out.second  = buildSecondAdult(ld);
        return out;
    }

    // Clears a Primary or Second adult (Lead.LastName is required, so Primary cannot be fully blanked).
    @AuraEnabled
    public static ParentList deleteParent(Id leadId, String role) {
        String rl = safeTrim(role);
        if (rl != ROLE_PRIMARY && rl != ROLE_SECOND) {
            throw buildError('Role must be Primary or Second.');
        }
        Lead ld = queryLead(leadId);
        if (rl == ROLE_PRIMARY) {
            ld.FirstName = null;
            ld.Email     = null;
            ld.Phone     = null;
        } else {
            ld.Parent_2_Name_First_Last__c = null;
            ld.Parent_2_Email__c = null;
            ld.Parent_2_Phone__c = null;
            ld.Second_Adult_Type__c = null;
        }
        update ld;
        return getParents(leadId);
    }

    private static Lead queryLead(Id leadId) {
        if (leadId == null) throw buildError('Lead Id is required.');
        List<Lead> results = [
            SELECT Id, Name,
                   No_of_Student_Enrolling_Today__c,
                   Student_Name__c, Student_Email__c, Student_s_Current_Grade__c, Student_ID_1__c,
                   Student_2_Name__c, Student_2_Email__c, Student_2_Grade__c, Student_ID_2__c,
                   Student_3_Name__c, Student_3_Email__c, Student_3_Grade__c, Student_ID_3__c,
                   Parent_1_Name_First_Last__c, Parent_1_Email__c, Parent_1_Phone__c, Parent_1_ID__c,
                   Parent_2_Name_First_Last__c, Parent_2_Email__c, Parent_2_Phone__c, Parent_2_ID__c,
                   Second_Adult_Type__c
            FROM Lead
            WHERE Id = :leadId
            LIMIT 1
        ];
        if (results.isEmpty()) throw buildError('Lead not found.');
        return results[0];
    }

    // Generates a "{prefix}-XXXXXXXX" identifier (~4 billion combinations) for a Parent or Student row.
    private static String generateUniqueId(String prefix) {
        String hex = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).toUpperCase();
        return prefix + '-' + hex.substring(0, 8);
    }

    private static String getStudentIdForSlot(Lead ld, Integer slot) {
        if (slot == 1) return ld.Student_ID_1__c;
        if (slot == 2) return ld.Student_ID_2__c;
        if (slot == 3) return ld.Student_ID_3__c;
        return null;
    }

    private static void setStudentIdForSlot(Lead ld, Integer slot, String value) {
        if (slot == 1) ld.Student_ID_1__c = value;
        else if (slot == 2) ld.Student_ID_2__c = value;
        else if (slot == 3) ld.Student_ID_3__c = value;
    }

    private static void validateSlot(Integer slot) {
        if (slot == null || slot < 1 || slot > MAX_STUDENTS) {
            throw buildError('Invalid student slot. Allowed: 1, 2, or 3.');
        }
    }

    private static Integer parseMaxStudents(String picklistValue) {
        if (String.isBlank(picklistValue)) return 0;
        try {
            Integer n = Integer.valueOf(picklistValue.trim());
            if (n < 0) return 0;
            return Math.min(n, MAX_STUDENTS);
        } catch (Exception e) {
            return 0;
        }
    }

    private static Boolean isSlotPopulated(Lead ld, Integer slot) {
        if (slot == 1) return String.isNotBlank(ld.Student_Name__c);
        if (slot == 2) return String.isNotBlank(ld.Student_2_Name__c);
        if (slot == 3) return String.isNotBlank(ld.Student_3_Name__c);
        return false;
    }

    private static Integer countPopulatedStudents(Lead ld) {
        Integer n = 0;
        if (isSlotPopulated(ld, 1)) n++;
        if (isSlotPopulated(ld, 2)) n++;
        if (isSlotPopulated(ld, 3)) n++;
        return n;
    }

    private static void applyStudentToLead(Lead ld, Integer slot, String fn, String ln, String em, String gr) {
        String combined = combineName(fn, ln);

        if (slot == 1) {
            ld.Student_Name__c = combined;
            ld.Student_Email__c = em;
            ld.Student_s_Current_Grade__c = gr;
        } else if (slot == 2) {
            ld.Student_2_Name__c = combined;
            ld.Student_2_Email__c = em;
            ld.Student_2_Grade__c = gr;
        } else if (slot == 3) {
            ld.Student_3_Name__c = combined;
            ld.Student_3_Email__c = em;
            ld.Student_3_Grade__c = gr;
        }
    }

    private static StudentDTO buildStudentFromCombined(Integer slot, String fullName, String email, String grade, String studentId) {
        StudentDTO dto = new StudentDTO();
        dto.slot = slot;
        String[] parts = splitName(fullName);
        dto.firstName = parts[0];
        dto.lastName = parts[1];
        dto.fullName = fullName;
        dto.email = email;
        dto.grade = grade;
        dto.populated = String.isNotBlank(fullName);
        dto.studentId = studentId;
        return dto;
    }

    private static AdultDTO buildPrimaryAdult(Lead ld) {
        String[] parts = splitName(ld.Parent_1_Name_First_Last__c);
        AdultDTO dto = new AdultDTO();
        dto.role = ROLE_PRIMARY;
        dto.type = 'Parent';
        dto.firstName = parts[0];
        dto.lastName = parts[1];
        dto.fullName = ld.Parent_1_Name_First_Last__c;
        dto.email = ld.Parent_1_Email__c;
        dto.phone = ld.Parent_1_Phone__c;
        dto.populated = String.isNotBlank(ld.Parent_1_Name_First_Last__c);
        dto.parentId = ld.Parent_1_ID__c;
        return dto;
    }

    private static AdultDTO buildSecondAdult(Lead ld) {
        String[] parts = splitName(ld.Parent_2_Name_First_Last__c);
        AdultDTO dto = new AdultDTO();
        dto.role = ROLE_SECOND;
        dto.type = ld.Second_Adult_Type__c;
        dto.firstName = parts[0];
        dto.lastName = parts[1];
        dto.fullName = ld.Parent_2_Name_First_Last__c;
        dto.email = ld.Parent_2_Email__c;
        dto.phone = ld.Parent_2_Phone__c;
        dto.populated = String.isNotBlank(ld.Parent_2_Name_First_Last__c);
        dto.parentId = ld.Parent_2_ID__c;
        return dto;
    }

    private static String combineName(String fn, String ln) {
        if (String.isBlank(fn) && String.isBlank(ln)) return null;
        if (String.isBlank(fn)) return ln;
        if (String.isBlank(ln)) return fn;
        return fn + ' ' + ln;
    }

    private static String[] splitName(String full) {
        String[] result = new String[]{ null, null };
        if (String.isBlank(full)) return result;
        String trimmed = full.trim();
        Integer idx = trimmed.indexOf(' ');
        if (idx < 0) {
            result[0] = trimmed;
        } else {
            result[0] = trimmed.substring(0, idx);
            result[1] = trimmed.substring(idx + 1).trim();
        }
        return result;
    }

    private static String safeTrim(String value) {
        return value == null ? null : value.trim();
    }

    private static Boolean isValidEmail(String email) {
        return Pattern.matches('^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$', email);
    }

    private static AuraHandledException buildError(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }
}