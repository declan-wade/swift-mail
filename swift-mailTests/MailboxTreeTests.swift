import Testing
@testable import swift_mail

struct MailboxTreeTests {
    private func mailbox(_ id: String, parent: String? = nil, role: String? = nil) -> Mailbox {
        Mailbox(id: id, name: id, role: role, parentId: parent, sortOrder: nil, totalEmails: nil, unreadEmails: nil)
    }

    @Test("Top-level mailboxes become roots and keep their input order")
    func flatListStaysFlat() {
        let nodes = MailboxNode.tree(from: [mailbox("A"), mailbox("B"), mailbox("C")])

        #expect(nodes.map(\.id) == ["A", "B", "C"])
        #expect(nodes.allSatisfy { $0.children == nil })
    }

    @Test("Child mailboxes nest under their parent")
    func childrenNestUnderParent() {
        let mailboxes = [
            mailbox("Banks"),
            mailbox("Up", parent: "Banks"),
            mailbox("Wise", parent: "Banks"),
            mailbox("Inbox", role: "inbox")
        ]

        let nodes = MailboxNode.tree(from: mailboxes)

        #expect(nodes.map(\.id) == ["Banks", "Inbox"])
        #expect(nodes.first?.children?.map(\.id) == ["Up", "Wise"])
    }

    @Test("A mailbox whose parent is absent is treated as a root, not dropped")
    func orphanBecomesRoot() {
        let nodes = MailboxNode.tree(from: [mailbox("Child", parent: "GoneParent")])

        #expect(nodes.map(\.id) == ["Child"])
    }

    @Test("Nesting recurses to arbitrary depth")
    func deepNesting() {
        let mailboxes = [
            mailbox("L1"),
            mailbox("L2", parent: "L1"),
            mailbox("L3", parent: "L2")
        ]

        let nodes = MailboxNode.tree(from: mailboxes)

        #expect(nodes.first?.children?.first?.children?.first?.id == "L3")
    }
}
