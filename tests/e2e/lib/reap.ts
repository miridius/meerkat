import { reapOrphanedBackends, reapOrphanedFixtures } from "./runner.js";

export default async function globalTeardown(): Promise<void> {
	await reapOrphanedBackends();
	reapOrphanedFixtures();
}
