import Foundation
import Testing
@testable import swift_mail

/// The close-confirmation only earns its interruption if it fires on real
/// edits and stays quiet otherwise.
struct ComposeDraftChangesTests {
    private let address = EmailAddress(name: "Ana", email: "ana@example.com")

    private func attachment(_ id: String) -> ComposeAttachment {
        ComposeAttachment(blobId: id, name: "\(id).txt", type: "text/plain", size: 10)
    }

    @Test("An untouched draft reports no changes")
    func untouchedIsClean() {
        let draft = ComposeDraft.blank(identity: nil)

        #expect(!draft.hasChanges(from: draft))
    }

    @Test("The identity filled in after opening is not a user edit")
    func identityIsNotAnEdit() {
        let original = ComposeDraft.blank(identity: nil)
        var draft = original
        draft.identityID = "identity-1"

        // The compose window sets this itself on appear; prompting for it would
        // mean every untouched New Message asks to be saved.
        #expect(!draft.hasChanges(from: original))
    }

    @Test("Each field the user can edit counts as a change")
    func editedFieldsAreChanges() {
        let original = ComposeDraft.blank(identity: nil)

        var body = original
        body.markdown = "Hello"
        #expect(body.hasChanges(from: original))

        var subject = original
        subject.subject = "Update"
        #expect(subject.hasChanges(from: original))

        var recipients = original
        recipients.to = [address]
        #expect(recipients.hasChanges(from: original))

        var copied = original
        copied.cc = [address]
        #expect(copied.hasChanges(from: original))

        var blind = original
        blind.bcc = [address]
        #expect(blind.hasChanges(from: original))

        var attached = original
        attached.attachments = [attachment("a")]
        #expect(attached.hasChanges(from: original))
    }

    @Test("A reply is clean until it is actually edited")
    func replyIsCleanUntilEdited() {
        // A reply opens pre-seeded with quoted text; that is not an unsaved edit.
        var reply = ComposeDraft.blank(identity: nil)
        reply.markdown = "\n\n> Original message"
        reply.to = [address]
        let opened = reply

        #expect(!reply.hasChanges(from: opened))

        reply.markdown = "Thanks!\n\n> Original message"
        #expect(reply.hasChanges(from: opened))
    }

    @Test("Removing an attachment is a change, and re-adding it is not")
    func attachmentChangesRoundTrip() {
        var original = ComposeDraft.blank(identity: nil)
        original.attachments = [attachment("a"), attachment("b")]

        var draft = original
        draft.attachments.removeLast()
        #expect(draft.hasChanges(from: original))

        draft.attachments.append(attachment("b"))
        #expect(!draft.hasChanges(from: original))
    }
}
