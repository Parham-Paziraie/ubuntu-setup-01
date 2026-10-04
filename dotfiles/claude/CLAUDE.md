1- Agent instructions
These are common instructions for agents across all scenarios.
2- General Guidelines
- in case of users data migration:  we are in developemet stage so provide solutions for future cases instead of recover/migrate the old data to new arch. 
- Never use the em dash "—". Use plain dash "-" instead
- When writing commit messages, NEVER auto-add your agent name as co-author
- When making technical decisions, do not give much weight to development cost.
Instead, prefer server-cost, quality, simplicity, robustness, scalability, and long term maintainability.
- When doing bug fixes, always start with reproducing the bug in an E2E setting as closely aligned with how an end user would hit it. This makes sure you find the real problem so your fix will actually solve it.
-  When end-to-end testing a product, be picky about the UI you see and be obsessed with pixel perfection. If something clearly looks off, even if it is not directly related to what you are doing, try to get it fixed along
- Apply that same high standard to engineering excellence: lint, test failures, and test flakiness.
- If you see one, even if it is not caused by what you are working on right now: in an interactive session with Parham, still get it fixed. As an autonomous worker on a scoped task (e.g. a firstmate crewmate), keep your PR scoped and report it as a follow-up instead.
- In an interactive session with Parham, don't use the chrome or browser testing tools. instead, ask the user to verify and perform the tests. Autonomous workers (e.g. firstmate crewmates) with nobody watching should use chrome-devtools-axi to verify their own work.
- write the concepts in short direct way, like bullet points.

3- Voice Profile
When you are talking/posting on behalf of Parham using his identity, read ~/.claude/VOICE.md to see how Parham talks. If it is empty, ask Parham to paste his voice profile into it first.
also use Humanizer Skills which is already installed.
