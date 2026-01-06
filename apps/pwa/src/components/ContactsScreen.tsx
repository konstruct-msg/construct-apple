import React, { useState } from 'react';
import './ContactsScreen.css';

interface Contact {
  id: string;
  name: string;
  publicKey?: string;
}

const ContactsScreen: React.FC = () => {
  const [contacts] = useState<Contact[]>([
    { id: '1', name: 'alice', publicKey: 'mQ3XK...' },
    { id: '2', name: 'bob', publicKey: 'nR4YL...' },
    { id: '3', name: 'charlie', publicKey: 'oS5ZM...' },
  ]);

  const handleAddContact = () => {
    // TODO: Implement QR code scanner / manual add
    console.log('Add contact');
  };

  return (
    <div className="contacts-screen">
      <div className="contacts-header">
        <h1 className="mono">CONTACTS</h1>
        <button className="add-contact-btn mono" onClick={handleAddContact}>
          + ADD
        </button>
      </div>

      <div className="contacts-list">
        {contacts.length === 0 ? (
          <div className="empty-state">
            <p className="mono">NO CONTACTS</p>
            <p className="hint">Tap + to add a contact</p>
          </div>
        ) : (
          contacts.map((contact) => (
            <div key={contact.id} className="contact-item">
              <div className="contact-name mono">{contact.name}</div>
              {contact.publicKey && (
                <div className="contact-key mono">{contact.publicKey}</div>
              )}
            </div>
          ))
        )}
      </div>
    </div>
  );
};

export default ContactsScreen;
