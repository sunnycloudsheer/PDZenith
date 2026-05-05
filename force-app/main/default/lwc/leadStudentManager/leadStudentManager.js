import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import { getRecord, getRecordNotifyChange } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';

import LEAD_OBJECT from '@salesforce/schema/Lead';
// Slot 1's grade is stored in Student_s_Current_Grade__c (Student's Current Grade);
// slots 2 and 3 use Student_2_Grade__c / Student_3_Grade__c.
import STUDENT_1_GRADE_FIELD from '@salesforce/schema/Lead.Student_s_Current_Grade__c';
import STUDENT_2_GRADE_FIELD from '@salesforce/schema/Lead.Student_2_Grade__c';
import STUDENT_3_GRADE_FIELD from '@salesforce/schema/Lead.Student_3_Grade__c';
import NUM_STUDENTS_FIELD    from '@salesforce/schema/Lead.No_of_Student_Enrolling_Today__c';

import getStudents from '@salesforce/apex/LeadFamilyController.getStudents';
import saveStudent from '@salesforce/apex/LeadFamilyController.saveStudent';
import deleteStudent from '@salesforce/apex/LeadFamilyController.deleteStudent';

const MAX_STUDENTS = 3;
const BLANK_FORM = Object.freeze({ slot: null, firstName: '', lastName: '', email: '', grade: '' });

export default class LeadStudentManager extends LightningElement {
    @api recordId;
    // Retained for backwards compatibility — the component no longer renders
    // its own section header, but this @api stays so existing App Builder
    // pages that set the property continue to deploy.
    @api sectionTitle;

    @track data;
    @track form = { ...BLANK_FORM };

    isModalOpen = false;
    isEditMode = false;
    isLoading = false;
    isSaving = false;

    _wired;

    @wire(getStudents, { leadId: '$recordId' })
    wiredStudents(result) {
        this._wired = result;
        if (result.data) {
            this.data = result.data;
        } else if (result.error) {
            this.showToast('Error', this.extractError(result.error), 'error');
        }
    }

    @wire(getRecord, { recordId: '$recordId', fields: [NUM_STUDENTS_FIELD] })
    leadRecord;

    @wire(getObjectInfo, { objectApiName: LEAD_OBJECT })
    leadObjectInfo;

    @wire(getPicklistValues, {
        recordTypeId: '$leadObjectInfo.data.defaultRecordTypeId',
        fieldApiName: STUDENT_1_GRADE_FIELD
    })
    gradePicklist1;

    @wire(getPicklistValues, {
        recordTypeId: '$leadObjectInfo.data.defaultRecordTypeId',
        fieldApiName: STUDENT_2_GRADE_FIELD
    })
    gradePicklist2;

    @wire(getPicklistValues, {
        recordTypeId: '$leadObjectInfo.data.defaultRecordTypeId',
        fieldApiName: STUDENT_3_GRADE_FIELD
    })
    gradePicklist3;

    get gradeOptions() {
        // Slot 1 reads Student_s_Current_Grade__c, slot 2 reads
        // Student_2_Grade__c, slot 3 reads Student_3_Grade__c. All three are
        // separate restricted picklists, so we surface the one for the slot
        // currently being edited.
        const slot = Number(this.form.slot);
        let picklist = this.gradePicklist1;
        if (slot === 2) picklist = this.gradePicklist2;
        else if (slot === 3) picklist = this.gradePicklist3;

        const values = picklist?.data?.values;
        if (!values) return [];
        // Hide R-prefixed grade codes (R3, R4, R7, …) — kept on the Lead
        // picklist for legacy reasons but not selectable here. The student's
        // existing grade is preserved in the option list even if it's an
        // R-value so editing a legacy student doesn't blank the field.
        const current = this.form.grade;
        return values
            .filter(v => !/^r/i.test(v.value) || v.value === current)
            .map(v => ({ label: v.label, value: v.value }));
    }

    // ─── Derived ──────────────────────────────────────────
    get populatedStudents() {
        if (!this.data) return [];
        return this.data.students
            .filter(s => s.populated)
            .map(s => ({
                ...s,
                gradeDisplay: s.grade || '—',
                emailDisplay: s.email || '—'
            }));
    }

    get hasStudents() {
        return this.populatedStudents.length > 0;
    }

    get maxAllowed() {
        const v = this.leadRecord?.data?.fields?.No_of_Student_Enrolling_Today__c?.value;
        if (!v) return 0;
        const n = parseInt(v, 10);
        if (isNaN(n) || n < 0) return 0;
        return Math.min(n, MAX_STUDENTS);
    }

    get isAddDisabled() {
        return this.isLoading || this.populatedStudents.length >= this.maxAllowed;
    }

    get capNotSet() {
        return this.maxAllowed === 0;
    }

    get modalTitle() {
        return this.isEditMode
            ? `Edit Student ${this.form.slot}`
            : `Add Student ${this.form.slot || ''}`.trim();
    }

    // ─── Add/Edit Student Modal ───────────────────────────
    handleOpenAdd() {
        if (this.capNotSet) {
            this.showToast(
                'Set the count first',
                'Pick a value for "# of Students Enrolling Today" before adding students.',
                'warning'
            );
            return;
        }
        if (this.isAddDisabled) {
            this.showToast('Limit reached', `Only ${this.maxAllowed} student(s) allowed.`, 'warning');
            return;
        }
        const nextSlot = this.firstEmptySlot();
        if (nextSlot == null) return;
        this.isEditMode = false;
        this.form = { ...BLANK_FORM, slot: nextSlot };
        this.isModalOpen = true;
    }

    handleOpenEdit(event) {
        const slot = Number(event.currentTarget.dataset.slot);
        const s = this.data.students.find(x => x.slot === slot);
        if (!s) return;
        this.isEditMode = true;
        this.form = {
            slot,
            firstName: s.firstName || '',
            lastName: s.lastName || '',
            email: s.email || '',
            grade: s.grade || ''
        };
        this.isModalOpen = true;
    }

    handleCloseModal() {
        this.isModalOpen = false;
    }

    handleInput(event) {
        const { name, value } = event.target;
        this.form = { ...this.form, [name]: value };
    }

    async handleSave() {
        if (!this.validateModalForm()) return;
        this.isSaving = true;
        try {
            const { slot, firstName, lastName, email, grade } = this.form;
            await saveStudent({ leadId: this.recordId, slot, firstName, lastName, email, grade });
            await refreshApex(this._wired);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this.isModalOpen = false;
            this.showToast('Saved', `Student ${slot} saved.`, 'success');
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (err) {
            this.showToast('Error', this.extractError(err), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleDelete(event) {
        const slot = Number(event.currentTarget.dataset.slot);
        // eslint-disable-next-line no-alert
        if (!window.confirm(`Remove Student ${slot}?`)) return;
        this.isLoading = true;
        try {
            await deleteStudent({ leadId: this.recordId, slot });
            await refreshApex(this._wired);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this.showToast('Removed', `Student ${slot} removed.`, 'success');
        } catch (err) {
            this.showToast('Error', this.extractError(err), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ─── Helpers ──────────────────────────────────────────
    firstEmptySlot() {
        if (!this.data) return null;
        const cap = this.maxAllowed;
        const found = this.data.students.find(s => !s.populated && s.slot <= cap);
        return found ? found.slot : null;
    }

    validateModalForm() {
        const inputs = [
            ...this.template.querySelectorAll('.slds-modal lightning-input'),
            ...this.template.querySelectorAll('.slds-modal lightning-combobox')
        ];
        return inputs.reduce((valid, el) => {
            el.reportValidity();
            return valid && el.checkValidity();
        }, true);
    }

    extractError(err) {
        // Log the raw shape so we can diagnose anything the parser misses.
        // eslint-disable-next-line no-console
        console.error('LeadStudentManager error:', err);
        if (!err) return 'Unknown error.';
        if (typeof err === 'string') return err;

        // AuraHandledException → err.body.message
        if (err.body?.message) return err.body.message;

        // DML page errors
        if (err.body?.pageErrors?.length) {
            return err.body.pageErrors.map(e => e.message).join(', ');
        }

        // Field-level validation errors
        if (err.body?.fieldErrors && typeof err.body.fieldErrors === 'object') {
            const msgs = [];
            for (const k of Object.keys(err.body.fieldErrors)) {
                const list = err.body.fieldErrors[k];
                if (Array.isArray(list)) msgs.push(...list.map(e => e.message));
            }
            if (msgs.length) return msgs.join(', ');
        }

        // Output errors (REST-style)
        if (err.body?.output?.errors?.length) {
            return err.body.output.errors.map(e => e.message).join(', ');
        }

        // Array body
        if (Array.isArray(err.body)) {
            const msgs = err.body.map(b => b?.message).filter(Boolean);
            if (msgs.length) return msgs.join(', ');
        }

        if (err.message) return err.message;

        try {
            return JSON.stringify(err.body || err);
        } catch (e) {
            return 'Unknown error.';
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
