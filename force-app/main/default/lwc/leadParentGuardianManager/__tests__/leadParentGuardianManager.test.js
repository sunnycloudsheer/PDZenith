import { createElement } from '@lwc/engine-dom';
import LeadParentGuardianManager from 'c/leadParentGuardianManager';
import getParents from '@salesforce/apex/LeadFamilyController.getParents';

jest.mock(
    '@salesforce/apex/LeadFamilyController.getParents',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/LeadFamilyController.saveParent',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/LeadFamilyController.deleteParent',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const LEAD_ID = '00Qbb00000Mgt8HEAR';

function emptyAdult(role) {
    return {
        role,
        type: role === 'Primary' ? 'Parent' : null,
        firstName: null,
        lastName: null,
        fullName: null,
        email: null,
        phone: null,
        populated: false
    };
}

function populatedAdult(role, first, last, type = 'Parent') {
    return {
        role,
        type,
        firstName: first,
        lastName: last,
        fullName: `${first} ${last}`,
        email: null,
        phone: null,
        populated: true
    };
}

function mount({ primary, second }) {
    const el = createElement('c-lead-parent-guardian-manager', { is: LeadParentGuardianManager });
    el.recordId = LEAD_ID;
    document.body.appendChild(el);
    getParents.emit({ leadId: LEAD_ID, primary, second });
    return el;
}

async function flush() {
    return Promise.resolve();
}

describe('c-lead-parent-guardian-manager', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows empty state when neither Parent 1 nor Parent 2 is populated', async () => {
        const el = mount({ primary: emptyAdult('Primary'), second: emptyAdult('Second') });
        await flush();

        expect(el.shadowRoot.textContent).toContain('No parents added yet.');
        expect(el.shadowRoot.querySelectorAll('tbody tr').length).toBe(0);
    });

    it('shows Parent 1 row sourced from Lead fields', async () => {
        const el = mount({
            primary: populatedAdult('Primary', 'Pat', 'Parent'),
            second: emptyAdult('Second')
        });
        await flush();

        const text = el.shadowRoot.textContent;
        expect(text).toContain('Parent 1');
        expect(text).toContain('Pat Parent');

        const addBtn = el.shadowRoot.querySelector('lightning-button[label="Add Parent / Guardian"]');
        expect(addBtn.disabled).toBe(false);
    });

    it('shows both rows and disables Add when both populated', async () => {
        const el = mount({
            primary: populatedAdult('Primary', 'Pat', 'Parent'),
            second: populatedAdult('Second', 'Gabby', 'Guard', 'Guardian')
        });
        await flush();

        const text = el.shadowRoot.textContent;
        expect(text).toContain('Pat Parent');
        expect(text).toContain('Gabby Guard');
        expect(text).toContain('Guardian');

        const addBtn = el.shadowRoot.querySelector('lightning-button[label="Add Parent / Guardian"]');
        expect(addBtn.disabled).toBe(true);
    });
});
