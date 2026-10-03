# Template topology is shared; Compose is checked against it

The Template has a shared topology definition for the Core and the `vo` Profile, including library and download folders. Wiring, host preparation and verification consume the relevant parts. Compose remains handwritten and is checked against that definition in CI: this keeps the deployment inspectable without introducing a Compose generator, at the cost of retaining some declarations in two places.

The definition describes Template defaults, not the current configuration of an Instance. Existing Operator configuration keeps priority under ADR-0002; topology does not authorise Wiring to reconcile or overwrite it. Instance-specific data stays outside git under ADR-0001. Other Profiles, the Worker and public access routes are outside this initial scope.

Use JSON and a shared Python reader with no third-party packages. This adds Python 3 as an explicit host prerequisite for preparation and verification, avoiding separate Bash and Python interpretations of the data. Model internal listener ports separately from host publications, and resolve internal addresses according to whether the caller shares the target's network namespace.

## Considered Options

- Generate Compose from the shared definition: fewer duplicated declarations, but adds a generation step and makes the deployed configuration less direct to maintain.
- Derive all topology from Compose: reuses the deployment model, but does not describe download categories or library roots configured through app APIs.

## Consequences

- A port change may require editing both the shared definition and Compose. CI must fail if they disagree; the guarantee is detected drift, not a single edit for every change.
- App data directories and their ownership remain in the existing host preparation and Profile definitions. Only library and download folders belong to this topology contract.
- Fast consistency checks are mandatory in PR CI. The real-app integration test remains manual because it downloads approximately 3 GB and starts the apps.
- The shared definition and reader live in `stacks/wire/wire/topology.json` and `topology.py`, so the same files are available to host scripts and included in the Wiring image. Design and acceptance criteria are recorded in `docs/research/template-topology.md`.
