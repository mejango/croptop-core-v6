# Held fallbacks: no try/catch branch may redirect value

- [x] CTPublisher: a Croptop fee the fee project could not take (no terminal, or `pay` reverted) is held in
      `heldFeeOf[token][feeBeneficiary]` instead of being refunded to the poster. `processHeldFeeOf` retries with no
      catch. `_refundFee` goes away.
- [ ] Tests: out of scope for this PR.
