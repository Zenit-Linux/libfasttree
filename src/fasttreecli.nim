import std/os
import fasttree/cli

proc printUsage() =
  echo """
fasttree — content-addressable następca OSTree

Użycie:
  fasttree pull <registry>/<repo>:<tag>
  fasttree status [--diff]
  fasttree deploy <tag> [--atomic]
  fasttree pin <tag> "<notatka>"
  fasttree gc [--dry-run]
  fasttree overlay create <nazwa> [--ephemeral]
  fasttree overlay remove <nazwa>
"""

proc main() =
  let args = commandLineParams()
  if args.len == 0:
    printUsage()
    quit(1)

  case args[0]
  of "pull":
    if args.len < 2: printUsage(); quit(1)
    cmdPull(args[1])
  of "status":
    cmdStatus(showDiff = "--diff" in args)
  of "deploy":
    if args.len < 2: printUsage(); quit(1)
    cmdDeploy(args[1], atomic = "--atomic" in args)
  of "pin":
    if args.len < 3: printUsage(); quit(1)
    cmdPin(args[1], args[2])
  of "gc":
    cmdGc(dryRun = "--dry-run" in args)
  of "overlay":
    if args.len < 3: printUsage(); quit(1)
    case args[1]
    of "create": cmdOverlayCreate(args[2], ephemeral = "--ephemeral" in args)
    of "remove": cmdOverlayRemove(args[2])
    else: printUsage(); quit(1)
  else:
    printUsage()
    quit(1)

when isMainModule:
  main()
