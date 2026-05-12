import Testing
import ArtifactCore
import ArtifactRenderer
import ArtifactNativeRenderer

@Suite("SVGRenderer.refine + PartialSVGScanner")
struct SVGRefinerTests {

    private func artifact(payload: String, isComplete: Bool) -> AnyArtifact {
        AnyArtifact(
            id: ArtifactIdentifier("s"),
            type: .svg,
            payload: payload,
            isComplete: isComplete
        )
    }

    // MARK: - Opening tag streaming

    @Test func payloadBeforeSvgTagYieldsPreRenderable() {
        let result = SVGRenderer.refine(artifact(payload: "<sv", isComplete: false))
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable until `<svg` is matched")
        }
    }

    @Test func payloadWithIncompleteSvgOpenTagYieldsPreRenderable() {
        // `<svg ` started but no closing `>` yet.
        let result = SVGRenderer.refine(artifact(
            payload: #"<svg xmlns="http://www.w3.org/2000/svg"#,
            isComplete: false
        ))
        if case .preRenderable = result {
            // OK
        } else {
            Issue.record("Expected .preRenderable while <svg ...> is still streaming")
        }
    }

    @Test func selfClosingSvgRootIsReturnedAsIs() {
        let payload = #"<svg xmlns="http://www.w3.org/2000/svg"/>"#
        let result = SVGRenderer.refine(artifact(payload: payload, isComplete: false))
        #expect(result == .renderable(payload))
    }

    @Test func openSvgWithNoChildrenIsWrappedSyntheticClose() {
        let result = SVGRenderer.refine(artifact(
            payload: #"<svg viewBox="0 0 10 10">"#,
            isComplete: false
        ))
        guard case let .renderable(prefix) = result else {
            Issue.record("Expected .renderable once `<svg>` has closed its open tag")
            return
        }
        #expect(prefix.hasSuffix("</svg>"))
        #expect(prefix.contains("<svg"))
    }

    // MARK: - Child element completion

    @Test func selfClosingChildIsIncludedAndTrailingPartialIsDropped() throws {
        let result = SVGRenderer.refine(artifact(
            payload: #"<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="3"/><rec"#,
            isComplete: false
        ))
        guard case let .renderable(prefix) = result else {
            Issue.record("Expected .renderable once a child completes")
            return
        }
        #expect(prefix.contains("<circle"))
        #expect(prefix.contains("<rec") == false)
        #expect(prefix.hasSuffix("</svg>"))
    }

    @Test func unclosedContainerElementIsDroppedEntirely() {
        let half = #"<svg><g><circle cx="1" cy="1" r="1"/>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: half, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        // The unclosed <g> wraps the circle — the entire subtree must not
        // leak into the renderable output.
        #expect(prefix.contains("<g>") == false)
        #expect(prefix.contains("<circle") == false)
        #expect(prefix.hasSuffix("</svg>"))
    }

    // MARK: - Nesting (the depth-tracking property)

    @Test func nestedSameNameElementsAreClosedAtCorrectDepth() throws {
        // The naive (flat search) implementation would close the OUTER <g>
        // at the inner `</g>` and emit invalid XML. The depth-tracking
        // walker must keep the outer <g> on the stack until its own close
        // tag arrives.
        let half = #"<svg><g><g><circle/></g>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: half, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        // Neither <g> has been fully closed yet, so the entire subtree must
        // be omitted from the output.
        #expect(prefix.contains("<g>") == false)
        #expect(prefix.contains("<circle") == false)
        #expect(prefix.hasSuffix("</svg>"))
    }

    @Test func nestedSameNameElementsAreIncludedWhenBothClosed() throws {
        let payload = #"<svg><g><g><circle/></g></g><rect/>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        // Both levels of <g> closed → the nested subtree appears. The
        // trailing self-closed <rect/> also completes.
        #expect(prefix.contains("<g><g><circle/></g></g>"))
        #expect(prefix.contains("<rect/>"))
        #expect(prefix.hasSuffix("</svg>"))
    }

    @Test func nestedDifferentNameElementsAreHandled() throws {
        let payload = #"<svg><g><text>hi</text></g><rec"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix.contains("<g><text>hi</text></g>"))
        #expect(prefix.contains("<rec") == false)
        #expect(prefix.hasSuffix("</svg>"))
    }

    // MARK: - XML quoting

    @Test func attributeContainingAngleBracketIsRespected() throws {
        // The `>` inside the attribute value must not be mistaken for the
        // tag close.
        let payload = #"<svg><text title="3 > 2">hi</text>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix.contains(#"<text title="3 > 2">hi</text>"#))
        #expect(prefix.hasSuffix("</svg>"))
    }

    @Test func singleQuotedAttributeIsRespected() throws {
        let payload = #"<svg><text title='a > b'>hi</text>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix.contains("<text title='a > b'>hi</text>"))
    }

    // MARK: - CDATA / comments / processing instructions

    @Test func commentContainingAngleBracketsIsSkipped() throws {
        let payload = #"<svg><!-- <fake/> not a real tag --><circle/>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        // The comment body is preserved verbatim — the `<fake/>` substring
        // appears only as part of the comment, never as an element on the
        // tag stack.
        #expect(prefix.contains("<!-- <fake/> not a real tag -->"))
        #expect(prefix.contains("<circle/>"))
        #expect(prefix.hasSuffix("</svg>"))
    }

    @Test func unterminatedCommentSuppressesFollowingContent() throws {
        let payload = #"<svg><circle/><!-- still streaming"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        // <circle/> completed before the comment, so it survives. The
        // unfinished comment is dropped.
        #expect(prefix.contains("<circle/>"))
        #expect(prefix.contains("<!--") == false)
        #expect(prefix.hasSuffix("</svg>"))
    }

    @Test func cdataSectionWithAngleBracketsIsSkipped() throws {
        let payload = #"<svg><style><![CDATA[ .a > .b { color: red; } ]]></style><circle/>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix.contains("<![CDATA["))
        #expect(prefix.contains("]]>"))
        #expect(prefix.contains("<circle/>"))
        #expect(prefix.hasSuffix("</svg>"))
    }

    @Test func unterminatedCdataSuppressesFollowingContent() throws {
        let payload = #"<svg><circle/><style><![CDATA[ .a > .b "#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        // <circle/> survives; the unfinished <style> with open CDATA is
        // dropped.
        #expect(prefix.contains("<circle/>"))
        #expect(prefix.contains("<style") == false)
        #expect(prefix.hasSuffix("</svg>"))
    }

    @Test func processingInstructionIsSkipped() throws {
        let payload = #"<svg><?xml-stylesheet href="a.css"?><circle/>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix.contains("<?xml-stylesheet"))
        #expect(prefix.contains("?>"))
        #expect(prefix.contains("<circle/>"))
    }

    // MARK: - Already-closed root

    @Test func fullyClosedSvgRootIsReturnedWithoutSyntheticClose() throws {
        let payload = #"<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="3"/></svg>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        // The walker found the natural close; we must not double-append
        // `</svg>`.
        #expect(prefix == payload)
        let occurrences = prefix.components(separatedBy: "</svg>").count - 1
        #expect(occurrences == 1)
    }

    @Test func completePayloadFlagReturnsRaw() {
        let payload = #"<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="3"/></svg>"#
        let result = SVGRenderer.refine(artifact(payload: payload, isComplete: true))
        #expect(result == .renderable(payload))
    }

    // MARK: - Namespaces / case

    @Test func namespacedTagsArePairedConsistently() throws {
        let payload = #"<svg><svg:g><svg:circle/></svg:g><rect/>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        #expect(prefix.contains("<svg:g><svg:circle/></svg:g>"))
        #expect(prefix.contains("<rect/>"))
        #expect(prefix.hasSuffix("</svg>"))
    }

    @Test func endTagWithoutOpeningStopsAtLastBalancedPoint() throws {
        let payload = #"<svg><circle/></g>"#
        guard case let .renderable(prefix) = SVGRenderer.refine(
            artifact(payload: payload, isComplete: false)
        ) else {
            Issue.record("Expected .renderable")
            return
        }
        // The orphan </g> halts the walk; <circle/> already completed.
        #expect(prefix.contains("<circle/>"))
        #expect(prefix.contains("</g>") == false)
        #expect(prefix.hasSuffix("</svg>"))
    }
}
