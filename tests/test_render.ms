-- Headless test, run by tests/run_tests.ps1 through 3dsmaxbatch.exe.
-- Loads the notifier from RN_TEST_DIR and renders three times.
(
    local dir = systemTools.getEnvVariable "RN_TEST_DIR"
    local f = createFile (dir + "\\result.txt")
    try
    (
        fileIn (dir + "\\render_notifier.ms")
        fileIn (dir + "\\render_notifier.ms") -- second load must not duplicate callbacks
        format "loaded=%\n" (::RenderNotifier != undefined) to:f
        format "callbacks=%\n" (callbacks.show id:#renderNotifier asArray:true).count to:f

        renderers.current = Default_Scanline_Renderer()
        box()

        -- fake Pulze Scene Manager 2.x data: SetupA is not queued, SetupB and SetupC are
        local js = (dotNetClass "System.IO.File").ReadAllText (dir + "\\sm.json")
        local ca = attributes SceneManager_Attributes ( parameters main ( SceneManager_Dat type:#string ) )
        custAttributes.add rootnode ca
        rootnode.SceneManager_Attributes.SceneManager_Dat = (dotNetClass "System.Convert").ToBase64String ((dotNetClass "System.Text.Encoding").UTF8.GetBytes js)

        rendOutputFilename = "C:\\rn_test\\SetupB.exr"
        render outputwidth:64 outputheight:48 vfb:off
        format "render1 ok\n" to:f

        rendOutputFilename = "C:\\rn_test\\SetupC.exr"
        render fromframe:0 toframe:2 outputwidth:64 outputheight:48 vfb:off
        format "render2 ok\n" to:f

        -- unreachable endpoint: the render must still work
        deleteFile (dir + "\\render_notifier.ini")
        copyFile (dir + "\\dead.ini") (dir + "\\render_notifier.ini")
        local bm = render outputwidth:64 outputheight:48 vfb:off
        format "render3 ok=%\n" (bm != undefined) to:f

        -- no config at all
        deleteFile (dir + "\\render_notifier.ini")
        render outputwidth:64 outputheight:48 vfb:off
        format "render4 ok\n" to:f

        -- 3ds Max dies in the middle of a render: the watchdog must report it
        copyFile (dir + "\\crash.ini") (dir + "\\render_notifier.ini")
        format "render5 start\n" to:f
        close f
        callbacks.addScript #preRenderFrame "((dotNetClass \"System.Diagnostics.Process\").GetCurrentProcess()).Kill()" id:#rnTestKill
        render outputwidth:64 outputheight:48 vfb:off
        f = openFile (dir + "\\result.txt") mode:"a"
        format "ERROR: 3ds Max survived the kill\n" to:f
    )
    catch (format "ERROR: %\n" (getCurrentException()) to:f)
    close f
)
