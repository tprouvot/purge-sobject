/**
 * @description Implemented by the optional modules that purge objects PurgeSObjectBatch can't delete itself.
 * PurgeSObjectBatch loads the known implementations by name with Type.forName, so the framework works without them.
 */
public interface PurgeSObjectHandler {
	/**
	 * @description Indicates if the module purges the object of this setting instead of PurgeSObjectBatch
	 * @param setting Custom metadata record, with all its fields
	 * @return `Boolean` true when the module handles the setting
	 */
	Boolean handles(PurgeSObjectSetting__mdt setting);

	/**
	 * @description Start the purge of the setting. Throw an exception to report an invalid configuration: the error is sent
	 * in the summary email and the purge continues with the next sequence. Otherwise, when the module is done with the setting,
	 * it must continue the chain with PurgeSObjectBatch.startSequenceAfter(sequence of the setting).
	 * @param setting Custom metadata record, with all its fields
	 */
	void start(PurgeSObjectSetting__mdt setting);

	/**
	 * @description Indicates if a purge started by the module is still running: the scheduled purge is then skipped
	 * @return `Boolean` true while the jobs of the module are running
	 */
	Boolean isRunning();
}
