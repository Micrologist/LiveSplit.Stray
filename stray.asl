state("Stray-Win64-Shipping"){}

startup
{
    vars.startTimeOffset = 0.567f;
    vars.endTimeStopwatch = new Stopwatch();
    vars.chaptersVisited = new List<String>() { "None" };

    // Asks user to change to game time if LiveSplit is currently set to Real Time.
    if (timer.CurrentTimingMethod == TimingMethod.RealTime)
    {        
        var timingMessage = MessageBox.Show (
            "This game uses Time without Loads (Game Time) as the main timing method.\n"+
            "LiveSplit is currently set to show Real Time (RTA).\n"+
            "Would you like to set the timing method to Game Time?",
            "LiveSplit | Stray",
            MessageBoxButtons.YesNo,MessageBoxIcon.Question
        );
        if (timingMessage == DialogResult.Yes)
        {
            timer.CurrentTimingMethod = TimingMethod.GameTime;
        }
    }

    vars.SetTextComponent = (Action<string, string>)((id, text) =>
    {
        var textSettings = timer.Layout.Components.Where(x => x.GetType().Name == "TextComponent").Select(x => x.GetType().GetProperty("Settings").GetValue(x, null));
        var textSetting = textSettings.FirstOrDefault(x => (x.GetType().GetProperty("Text1").GetValue(x, null) as string) == id);
        if (textSetting == null)
        {
            var textComponentAssembly = Assembly.LoadFrom("Components\\LiveSplit.Text.dll");
            var textComponent = Activator.CreateInstance(textComponentAssembly.GetType("LiveSplit.UI.Components.TextComponent"), timer);
            timer.Layout.LayoutComponents.Add(new LiveSplit.UI.Components.LayoutComponent("LiveSplit.Text.dll", textComponent as LiveSplit.UI.Components.IComponent));
            textSetting = textComponent.GetType().GetProperty("Settings", BindingFlags.Instance | BindingFlags.Public).GetValue(textComponent, null);
            textSetting.GetType().GetProperty("Text1").SetValue(textSetting, id);
        }
        if (textSetting != null)
            textSetting.GetType().GetProperty("Text2").SetValue(textSetting, text);
    });

    settings.Add("Splits", true, "Splits");
    settings.Add("chapterSplit", true, "Split on completing a chapter", "Splits");
    settings.Add("endSplit", true, "Split on completing the game", "Splits");
    settings.Add("prologueSplit", false, "Split on completing Prologue", "Splits");
    settings.Add("autoReset", false, "Reset on making a new save","Splits");

    settings.Add("100", false, "[100%] Optional Splits", "Splits");
    settings.Add("100Sewer", true, "Split on loading back into sewers", "100");

    settings.Add("ILMode", false, "[IL] Functions", "Splits");
    settings.Add("ILStart", true, "Start timer upon loading any chapter", "ILMode");
    settings.Add("ILReset", false, "Reset on main menu", "ILMode");

    settings.Add("debugTextComponents", false, "[DEBUG] Show tracked values in layout");
}

init
{
    //Version detection is not strictly needed as long as the sig scans work
    //But keeping a list of known versions can be useful later in case a new patch does break stuff
    int moduleSize = modules.First().ModuleMemorySize;
    switch (moduleSize)
    {
        case 89993216:
            version = "rev. 26237";
            break;
        case 91013120:
            version = "rev. 26195";
            break;
        case 91009024:
            version = "rev. 26176";
            break;
        case 91234304:
            version = "rev. 26161";
            break;
        default:                                
            version = "Unknown " + moduleSize.ToString();
            break;
    }

    vars.setStartTime = false;
    #region sigscanning
    vars.GetStaticPointerFromSig = (Func<string, int, IntPtr>) ( (signature, instructionOffset) => {
        var scanner = new SignatureScanner(game, modules.First().BaseAddress, (int)modules.First().ModuleMemorySize);
        var pattern = new SigScanTarget(signature);
        var location = scanner.Scan(pattern);
        if (location == IntPtr.Zero) return IntPtr.Zero;
        int offset = game.ReadValue<int>((IntPtr)location + instructionOffset);
        return (IntPtr)location + offset + instructionOffset + 0x4;
    });

    vars.GetNameFromFName = (Func<long, string>) ( longKey => {
        int key = (int)(longKey & uint.MaxValue);
        int partial = (int)(longKey >> 32);
        int chunkOffset = key >> 16;
        int nameOffset = (ushort)key;
        IntPtr namePoolChunk = memory.ReadValue<IntPtr>((IntPtr)vars.FNamePool + (chunkOffset+2) * 0x8);
        Int16 nameEntry = game.ReadValue<Int16>((IntPtr)namePoolChunk + 2 * nameOffset);
        int nameLength = nameEntry >> 6;
        string output = game.ReadString((IntPtr)namePoolChunk + 2 * nameOffset + 2, nameLength);
        return (partial == 0) ? output : output + "_" + partial.ToString();
    });
    
    vars.FNamePool = vars.GetStaticPointerFromSig("74 09 48 8D 15 ?? ?? ?? ?? EB 16", 0x5);
    vars.UWorld = vars.GetStaticPointerFromSig("0F 2E ?? 74 ?? 48 8B 1D ?? ?? ?? ?? 48 85 DB 74", 0x8);
    vars.GameEngine = vars.GetStaticPointerFromSig("48 89 05 ?? ?? ?? ?? 48 85 C9 74 05 E8 ?? ?? ?? ?? 48 8D 4D F0 E8", 0x3);

    if(vars.FNamePool == IntPtr.Zero || vars.UWorld == IntPtr.Zero || vars.GameEngine == IntPtr.Zero)
    {
        throw new Exception("FNamePool/UWorld/GameEngine not initialized - trying again");
    }
    #endregion
    vars.watchers = new MemoryWatcherList
    {
        new MemoryWatcher<int>(new DeepPointer(vars.GameEngine, 0xD28, 0x38, 0x0, 0x30, 0x2B8, 0x3F0)) { Name = "hudFlag"},
        new MemoryWatcher<IntPtr>(new DeepPointer(vars.GameEngine, 0xD28, 0xF0, 0xE0, 0x68)) { Name = "loadingAudioPtr" },
        new MemoryWatcher<long>(new DeepPointer(vars.GameEngine, 0xD28, 0x348, 0x90, 0x110)) { Name = "saveDataChapterFName" },
        new MemoryWatcher<long>(new DeepPointer(vars.GameEngine, 0xD28, 0x38, 0x0, 0x30, 0x608, 0xEA0, 0x18)) { Name = "camViewTargetFName"},
        new MemoryWatcher<long>(new DeepPointer(vars.UWorld, 0x18)) { Name = "worldFName"}
    };
}

update 
{
    #region Updates
    vars.watchers.UpdateAll(game);
    current.hudFlag = vars.watchers["hudFlag"].Current;
    current.loading = vars.watchers["loadingAudioPtr"].Current != IntPtr.Zero;
    current.chapter = vars.GetNameFromFName(vars.watchers["saveDataChapterFName"].Current);
    current.camTarget = vars.GetNameFromFName(vars.watchers["camViewTargetFName"].Current);
    var map = vars.GetNameFromFName(vars.watchers["worldFName"].Current);

    if(!String.IsNullOrEmpty(map) && map != "None")
    {
        current.map = map;
    }
    #endregion

    if(settings["debugTextComponents"])
    {
        vars.SetTextComponent("Map", current.map);
        vars.SetTextComponent("Chapter", current.chapter);
        vars.SetTextComponent("IsLoading", current.loading.ToString());
        vars.SetTextComponent("Cam Target", current.camTarget);
        vars.SetTextComponent("Hud Flag", current.hudFlag.ToString("X8"));
        vars.SetTextComponent("Chapters Visited", vars.chaptersVisited.Count.ToString());
    }
}

start
{
    if (current.camTarget == "cam1" || settings["ILStart"])
    {
        return (current.map == "BaseMap" && current.loading != old.loading && !current.loading);
    }
}

onStart
{
    vars.setStartTime = true;
    vars.chaptersVisited = new List<String>() { "None" };
    if(!settings["prologueSplit"])
    {
        vars.chaptersVisited.Add("InsideTheWall");
    }
    timer.IsGameTimePaused = true;
    vars.endTimeStopwatch.Reset();
}

reset
{
    if(settings["autoReset"] || settings["ILReset"])
    {
        return (current.loading != old.loading && current.camTarget == "cam1") || (settings["ILReset"] && current.map == "HK_Project_MainStart");
    }
}

split
{
    if(settings["chapterSplit"] || settings["ILMode"])
    {
        if(current.chapter != old.chapter && !vars.chaptersVisited.Contains(current.chapter))
        {
            vars.chaptersVisited.Add(current.chapter);
            if(old.chapter != "None" || current.chapter == "InsideTheWall")
            {
                return true;
            }
        }
    }

    if(settings["100Sewer"])
    {
        if(current.chapter == "None" && current.camTarget != old.camTarget && current.camTarget == "BP_SplineCamera_Cine_3")
        {
            return true;
        }
    }

    if(settings["endSplit"] || settings["ILMode"])
    {
        if(current.chapter == "ControlRoom" && current.camTarget == "BP_SplineCamera_4" && current.hudFlag != old.hudFlag && current.hudFlag == 0)
        {
            vars.endTimeOffset = 0.817f;
            vars.endTimeStopwatch.Restart();
        }
    }

    if(vars.endTimeStopwatch.IsRunning && vars.endTimeStopwatch.Elapsed.TotalSeconds >= vars.endTimeOffset)
    {
        vars.endTimeStopwatch.Reset();
        return true;
    }
}

isLoading
{
    return current.loading;
}

gameTime 
{
    if(vars.setStartTime)
    {
        vars.setStartTime = false;
        return TimeSpan.FromSeconds(vars.startTimeOffset);
    }
}  

exit
{
    timer.IsGameTimePaused = true;
}
