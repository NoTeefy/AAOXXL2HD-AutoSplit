/*
	Astérix & Obélix Auto-Splitter XXL 2 Mission: Las Vegum Remastered (with loadless timer)
	Version: 0.0.4
	Author: NoTeefy
	Compatible Versions: Steam | Standalone DRM-Free (GOG.com)
	Some code may be inspired by some referenced scripts and their authors: Avasam, DevilSquirrel, tduva, Darkid
	
	Thanks to Martyste for some ideas/inputs <3
*/
state("oXXL2Game") {
	
}

// Loading & func/var declaration
startup {
	vars.ver = "0.0.4";
	
	// Log Output switch for DebugView (enables/disables debug messages)
    var DebugEnabled = false;
    Action<string> DebugOutput = (text) => {
        if (DebugEnabled)
        {
			print(" «[AAORMSTR - v" + vars.ver + "]» " + text);
        }
    };
    vars.DebugOutput = DebugOutput;

	vars.DebugOutput("Initialising auto-splitter");
	settings.Add("isLoadless", true, "Use loadless timer");
	settings.Add("startOnlyNewFile", true, "Only start the timer on a fresh new file");
	
	Func<int, bool, bool, Tuple<int, bool, bool>> tc = Tuple.Create;
	vars.tc = tc;
	
	/* 
		We need a deep copy function to reset the levelProgression when a runner exits & stops his timer while keeping the game open for a new run
		while not touching the values/references from the template itself (gotta love native C base languages...)
	*/
	Func<List<Tuple<int, bool, bool>>, List<Tuple<int, bool, bool>>> deepCopy = (listToCopy) => {
        var newList = new List<Tuple<int, bool, bool>>{};
		foreach(var obj in listToCopy) {
			newList.Add(vars.tc(obj.Item1, obj.Item2, obj.Item3));
		}
		return newList;
    };
	vars.deepCopy = deepCopy;
	
	/*
		Resets all important/dynamic values back to their initial value (used if timer gets stopped before all splits were done)
	*/
	Action resetValues = () => {
		vars.initialized = false;
		vars.started = false;
		vars.startedVal = false;
		vars.lastLevel = 0;
		vars.levelPointerAdress = null;
		vars.finalBossStaticPointer = null;
		vars.lastFail = DateTime.Now.Millisecond;
	};
	vars.resetValues = resetValues;
	
	/*
		This is the level order which the splitter expects to happen
		Values: int = levelNum, bool = mustSplit, bool = hasVisited(level)
		! We can't use named tuple indices because we are under C# 7.0 => tuple.Item1, tuple.ItemX, tuple2.Item1, ... to read the values
	*/
	var levelTuples = new List<Tuple<int, bool, bool>>{ // we can't use named tuple indices because we are under C# 7.0, int = levelNum, bool = mustSplit, bool = hasVisited(level)
		tc(0, false, true), // unknown state/main-menu
		tc(1, false, false), // start
		tc(2, true, false),
		tc(8, false, false), // first boss
		tc(4, true, false),
		tc(9, false, false), // second boss
		tc(3, true, false),
		tc(6, true, false),
		tc(10, false, false), // third boss
		tc(7, true, false),
		tc(11, false, false) // final boss
	};
	
	vars.levelProgressionTemplate = levelTuples;
	vars.lastLevel = null; // is used to keep track of the last occurence from a split
	vars.levelProgression = vars.deepCopy(levelTuples);
	
	
	vars.levelPointerST = new SigScanTarget(0,
		"C0 ?? ?? ?? ?? ?? ?? 89 ?? ?? ?? ?? ?? EB 07 8B CF E8" // sig scan for "oXXL2Game.exe" + 00465A74 => holds a static address to the levelPointer + isLoading(0x2C)
    );
	
	vars.finalBossHitCountST = new SigScanTarget(0,
		"A3 ?? ?? ?? ?? 8B ?? ?? ?? ?? ?? 5F C7 83 ?? ?? ?? ?? ?? ?? ?? ?? 83 4B 10 03 A3" // sig scan for the static pointer holder of finalBoss (with an offset of 0x1)
	);
}

// process found + hooked by LiveSplit (init needed vars)
init {
	vars.DebugOutput("Attached autosplitter to game client");
	vars.DebugOutput("Starting to search for the ingame memory region");
	
	refreshRate = 70;
	vars.resetValues();
	
	var ptr = IntPtr.Zero;
	
	foreach (var page in game.MemoryPages(true)) {
		var scanner = new SignatureScanner(game, page.BaseAddress, (int)page.RegionSize);

		if (ptr == IntPtr.Zero) {
			ptr = scanner.Scan(vars.levelPointerST);
		} else {
			vars.levelPointerAdress = game.ReadPointer((IntPtr)ptr);
			vars.DebugOutput("sig scan found pointer at \"" + ptr.ToString("X") + "\" pointing to address \"" + vars.levelPointerAdress.ToString("X") + "\" which is the levelPointer");
			break;
		}
    }

    if (ptr == IntPtr.Zero) {
        /* 
			Waiting for the game to have booted up. This is a pretty ugly work
			around, but we don't really know when the game is booted or where the
			struct will be, so to reduce the amount of searching we are doing, we
			sleep a bit between every attempt.
		*/
        Thread.Sleep(1000);
        throw new Exception();
    }
	vars.levelState = new MemoryWatcher<int>(vars.levelPointerAdress);
	vars.isLoading = new MemoryWatcher<int>(vars.levelPointerAdress + 0x2C);
	
	vars.watchers = new MemoryWatcherList() {
        vars.levelState,
		vars.isLoading
    };
}

// gets triggered as often as refreshRate is set at | 70 = 1000ms / 70 => every 14ms
update {
	if(vars.initialized) {
		vars.watchers.UpdateAll(game);
		if (vars.levelState.Current != vars.levelState.Old) {
			vars.DebugOutput("levelState changed from " + vars.levelState.Old + " to " + vars.levelState.Current);
		}
		if (vars.isLoading.Current != vars.isLoading.Old) {
			vars.DebugOutput("isLoading changed from " + vars.isLoading.Old + " to " + vars.isLoading.Current);
		}
	}
	else {
		if(game.Handle != null) {
			if((int)game.Handle > 0) {
				vars.initialized = true;
				Thread.Sleep(3000); // wait 3 secs because the handle gets destroyed when the windows opens
			}
		}
	}
}

// Only runs when the timer is stopped
start {
	if(vars.levelState.Current > 0 && vars.isLoading.Current == 1 && !vars.started) {
		if(settings["startOnlyNewFile"] && vars.levelState.Current != 1) {
			return false;
		}
		else {
			vars.started = true;
			vars.startedVal = true;
			List<Tuple<int, bool, bool>> list = vars.levelProgression;
			var index = list.FindIndex(t => t.Item1 == vars.levelState.Current); // getting the levelNum
			vars.levelProgression[index] = vars.tc(vars.levelState.Current, false, true);
			vars.lastLevel = vars.levelState.Current;
			vars.DebugOutput("timer started and first progression entry changed to " + vars.levelProgression[index].Item1 + " " + vars.levelProgression[index].Item2 + " " + vars.levelProgression[index].Item3);
		}
	}
	else {
		if(vars.started) {
			vars.resetValues(); // resetting vals
			vars.levelProgression = vars.deepCopy(vars.levelProgressionTemplate); // resetting progression while preserving template for more resets
			vars.DebugOutput("resetting level progression because the timer got stopped");
		}
		vars.startedVal = false;
		
	}
	return vars.startedVal;
}

// Only runs when the timer is running
reset { // Resets the timer upon returning true
	// do nothing, we would need an additional pointer for the main menu detection and it's "marathon safe" friendly ;)
	return false;
}

// Splits upon returning true if reset isn't explicitly returning true
split {
	/*
		// This is only used to debug the finalBossDetection
		vars.lastLevel = 11;
	*/
	if(((vars.levelState.Current != vars.lastLevel) || vars.lastLevel == 11) && (vars.levelState.Current != 0)) {
		// levelState changed and it's not a switching scene
		List<Tuple<int, bool, bool>> list = vars.levelProgression;
		var index = list.FindIndex(t => t.Item1 == vars.lastLevel); // getting the levelObject from the last stage
		if(index + 1 < (vars.levelProgression.Count - 1)){
			// not the last stage
			var currLevelObj = vars.levelProgression[index + 1];
			if(currLevelObj.Item1 == vars.levelState.Current) {
				// stage did change and it's not a backtrack
				vars.lastLevel = (int)currLevelObj.Item1;
				currLevelObj = vars.tc(currLevelObj.Item1, currLevelObj.Item2, true);
				if(currLevelObj.Item2) {
					// needs a split
					return true;
				}
				return false;
			}
		}
		else {
			// last stage, splitting
			// check for boss final hit
			int msec = DateTime.Now.Millisecond;
			if(vars.finalBossStaticPointer == null && msec >= (vars.lastFail + 100)) {
				vars.DebugOutput("starting to search for final boss pointer");
				var ptr = IntPtr.Zero;
				foreach (var page in game.MemoryPages(true)) {
					var scanner = new SignatureScanner(game, page.BaseAddress, (int)page.RegionSize);

					if (ptr == IntPtr.Zero) {
						ptr = scanner.Scan(vars.finalBossHitCountST);
					} else {
						IntPtr finalBaseAddressPtr = new IntPtr(ptr.ToInt64());
						IntPtr finalBaseAddressPtr2 = IntPtr.Add(finalBaseAddressPtr, 0x1);
						int finalBaseAddress = memory.ReadValue<int>((IntPtr)finalBaseAddressPtr2);
						IntPtr finalPtr = new IntPtr(finalBaseAddress);
						var finalFileOffset = finalBaseAddress - (int)modules.First().BaseAddress;
						int[] offsets = new int[] {
							0x1AC,
							0x10,
							0x768
						};
						DeepPointer dP = new DeepPointer(finalFileOffset, offsets);
						var fB = dP.DerefBytes(game, 1); // would need an Array.Regverse(fB) because of Big/Little-Endian problems
						IntPtr resolvedPtr = new IntPtr();
						dP.DerefOffsets(game, out resolvedPtr);
						vars.DebugOutput("sig scan found finalBossPointerAddress at " + resolvedPtr.ToString("X"));
						if(fB != null && dP != null) {
							if(fB[0] == 3) {
								vars.finalBossStaticPointer = dP;
							}
						}
						break;
					}
				}

				if (ptr == IntPtr.Zero || vars.finalBossStaticPointer == null) {
					vars.lastFail = msec;
					vars.DebugOutput("failed to read finalBossStaticPointer");
					return false;
				}
			}
			else {
				var finalVal = vars.finalBossStaticPointer.DerefBytes(game, 1); // would need an Array.Regverse(fB) because of Big/Little-Endian problems
				if(vars.finalBossStaticPointer != null && finalVal != null) {
					// vars.DebugOutput("boss is at finalHits: " + finalVal[0]);
					if(finalVal[0] == 0) {
						// boss defeated, doing last split
						vars.DebugOutput("defeated boss and finalHits: " + finalVal[0]);
						return true;
					}
				}
				// boss not down yet
				return false;
			}
		}
	}
	return false;
}

// return true if timer needs to be stopped, return false if it should resume
isLoading {
	// stop the timer when in loading states (loadless timer, yay)
	return settings["isLoadless"] && (vars.isLoading.Current == 1 ? true : false);
}
