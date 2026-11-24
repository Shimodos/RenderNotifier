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

        render outputwidth:64 outputheight:48 vfb:off
        format "render1 ok\n" to:f

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
    )
    catch (format "ERROR: %\n" (getCurrentException()) to:f)
    close f
)
