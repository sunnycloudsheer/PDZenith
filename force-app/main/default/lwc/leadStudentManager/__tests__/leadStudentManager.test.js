import { createElement } from '@lwc/engine-dom';
import LeadStudentManager from 'c/leadStudentManager';
import getStudents from '@salesforce/apex/LeadFamilyController.getStudents';

jest.mock(
    '@salesforce/apex/LeadFamilyController.getStudents',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/LeadFamilyController.saveStudent',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/LeadFamilyController.deleteStudent',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const LEAD_ID = '00Qbb00000Mgt8HEAR';

function emptyStudent(slot) {
    return { slot, firstName: null, lastName: null, fullName: null, email: null, grade: null, populated: false };
}

function populatedStudent(slot, first, last, grade = null) {
    return {
        slot,
        firstName: first,
        lastName: last,
        fullName: `${first} ${last}`,
        email: null,
        grade,
        populated: true
    };
}

function mount(students) {
    const el = createElement('c-lead-student-manager', { is: LeadStudentManager });
    el.recordId = LEAD_ID;
    document.body.appendChild(el);
    getStudents.emit({ leadId: LEAD_ID, students });
    return el;
}

async function flush() {
    return Promise.resolve();
}

describe('c-lead-student-manager', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows empty prompt and enables Add when no students exist', async () => {
        const el = mount([emptyStudent(1), emptyStudent(2), emptyStudent(3)]);
        await flush();

        const addBtn = el.shadowRoot.querySelector('lightning-button[label="Add Student"]');
        expect(addBtn).not.toBeNull();
        expect(addBtn.disabled).toBe(false);
    });

    it('disables Add once 3 students are populated', async () => {
        const el = mount([
            populatedStudent(1, 'A', 'K', '10th'),
            populatedStudent(2, 'B', 'K', '8th'),
            populatedStudent(3, 'C', 'K', '6th')
        ]);
        await flush();

        const addBtn = el.shadowRoot.querySelector('lightning-button[label="Add Student"]');
        expect(addBtn.disabled).toBe(true);
    });

    it('renders one row per populated student', async () => {
        const el = mount([
            populatedStudent(1, 'A', 'K', '10th'),
            emptyStudent(2),
            populatedStudent(3, 'C', 'K', '6th')
        ]);
        await flush();

        const rows = el.shadowRoot.querySelectorAll('tbody tr');
        expect(rows.length).toBe(2);
    });
});
