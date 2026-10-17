import Foundation
import MapcCommand

exit(await Mapc.main(Array(CommandLine.arguments.dropFirst())))
