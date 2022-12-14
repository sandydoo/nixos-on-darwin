//
//  main.swift
//  NixOSRemoteBuilder
//
//  Created by Sander Melnikov on 22/11/2022.
//

import Foundation
import Virtualization

let vmBundlePath = NSHomeDirectory() + "/NixOSRemoteBuilder.bundle/"
let efiVariableStorePath = vmBundlePath + "NVRAM"
let mainDiskImagePath = vmBundlePath + "Disk.img"
let machineIdentifierPath = vmBundlePath + "MachineIdentifier"

enum VMError: Error {
    case cannotCreateVMBundle
    
    // Rosetta
    case rosettaIsNotSupported
    case rosettaIsNotAvailable
    
    // Machine Identifier
    case cannotGetMachineIdentifierData
    case cannotParseMachineIdentifier
    
    // EFI Variables
    case cannotGetEFIVariableStore
    case cannotCreateEFIVariableStore
    
    // Disks
    case cannotCreateMainDiskImage
    case cannotOpenFileHandleToMainDiskImage
    case cannotTruncateMainDiskImage
    case cannotCreateDiskImageAttachment
    case cannotCreateDiskArray
    
    // VM
    case cannotValidateVMConfiguration
    case cannotStartVirtualMachine(Error)
}

guard CommandLine.argc == 2 else {
    printUsageAndExit()
}

let isoURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: false)

let vmExists = FileManager.default.fileExists(atPath: vmBundlePath)

if !vmExists {
    do {
        try createVMBundle()
        try createMainDiskImage()
    } catch let error {
        print(error.localizedDescription)
        throw error
    }
}

do {
    print("Installing Rosetta...")
    try installRosetta()
} catch let error {
    fatalError(error.localizedDescription)
}

let configuration = try createVMConfiguration(isoURL: isoURL, vmExists: vmExists)

let tag = "rosetta"
do {
    let _ = try VZVirtioFileSystemDeviceConfiguration.validateTag(tag)
    let rosettaDirectoryShare = try VZLinuxRosettaDirectoryShare()
    let fileSystemDevice = VZVirtioFileSystemDeviceConfiguration(tag: tag)
    fileSystemDevice.share = rosettaDirectoryShare

    configuration.directorySharingDevices = [ fileSystemDevice ]
} catch {
    throw VMError.rosettaIsNotAvailable
}

do {
    try configuration.validate()
} catch {
    throw VMError.cannotValidateVMConfiguration
}

let virtualMachine = VZVirtualMachine(configuration: configuration)

let delegate = Delegate()
virtualMachine.delegate = delegate

virtualMachine.start { (result) in
    switch result {
    case let .failure(error):
        fatalError(error.localizedDescription)

    default:
        print("Launching VM...")
    }
}
    
RunLoop.main.run(until: Date.distantFuture)


// MARK: - Virtual Machine Delegate

class Delegate: NSObject {}

extension Delegate: VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("The guest shut down. Exiting.")
        exit(EXIT_SUCCESS)
    }
}

// MARK: - Helper functions

func installRosetta() throws {
    let rosettaAvailability = VZLinuxRosettaDirectoryShare.availability

    switch rosettaAvailability {
    case .notSupported:
        throw VMError.rosettaIsNotSupported

    case .notInstalled:
        // Ask the user for permission to install Rosetta, and
        // start the installation process if they grant permission.
        VZLinuxRosettaDirectoryShare.installRosetta(completionHandler: { error in
            let vzerror = error as! VZError
            switch vzerror.code {
            case .networkError:
                // A network error prevented the download from completing successfully.
                fatalError("There was a network error while installing Rosetta. Please try again.")
            case .outOfDiskSpace:
                // Not enough disk space on the system volume to complete the installation.
                fatalError("Your system does not have enough disk space to install Rosetta")
            case .operationCancelled:
                break
            case .notSupported:
                break
            default:
                break
            }
        })
        
        break

    case .installed:
        break // Ready to go.
    
    @unknown default:
        throw VMError.rosettaIsNotAvailable
    }

}

func createVMBundle() throws {
    do {
        try FileManager.default.createDirectory(atPath: vmBundlePath, withIntermediateDirectories: true)
    } catch {
        throw VMError.cannotCreateVMBundle
    }
}

func createVMConfiguration(isoURL: URL, vmExists: Bool) throws -> VZVirtualMachineConfiguration {
    let bootloader = VZEFIBootLoader()
    let platform = VZGenericPlatformConfiguration()
    
    if !vmExists {
        bootloader.variableStore = try createEFIVariableStore()
        platform.machineIdentifier = createMachineIdentifier(machineIdentifierPath: machineIdentifierPath)
    } else {
        bootloader.variableStore = try getEFIVariableStore()
        platform.machineIdentifier = try getMachineIdentifier(machineIdentifierPath: machineIdentifierPath)
    }

    // Create disks
    let disksArray = NSMutableArray()
    disksArray.add(try createUSBMassStorageDeviceConfiguration(isoURL: isoURL))
    disksArray.add(try createBlockDeviceConfiguration(diskImagePath: mainDiskImagePath))
    guard let disks = disksArray as? [VZStorageDeviceConfiguration] else {
        throw VMError.cannotCreateDiskArray
    }

    let configuration = VZVirtualMachineConfiguration()
    configuration.cpuCount = 2
    configuration.memorySize = 2 * 1024 * 1024 * 1024 // 2 GiB
    configuration.serialPorts = [ createConsoleConfiguration() ]
    configuration.bootLoader = bootloader
    configuration.platform = platform
    configuration.storageDevices = disks
    configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    configuration.networkDevices = [createNetworkDeviceConfiguration()]
    
    return configuration
}

func createEFIVariableStore() throws -> VZEFIVariableStore {
    guard let efiVariableStore = try? VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: efiVariableStorePath)) else {
        throw VMError.cannotCreateEFIVariableStore
    }
    
    return efiVariableStore
}
    
func getEFIVariableStore() throws -> VZEFIVariableStore {
    if !FileManager.default.fileExists(atPath: efiVariableStorePath) {
        throw VMError.cannotGetEFIVariableStore
    }
    
    return VZEFIVariableStore(url: URL(fileURLWithPath: efiVariableStorePath))
}

/// Creates a serial configuration object for a virtio console device,
/// and attaches it to stdin and stdout.
func createConsoleConfiguration() -> VZSerialPortConfiguration {
    let consoleConfiguration = VZVirtioConsoleDeviceSerialPortConfiguration()

    let inputFileHandle = FileHandle.standardInput
    let outputFileHandle = FileHandle.standardOutput

    // Put stdin into raw mode, disabling local echo, input canonicalization,
    // and CR-NL mapping.
    var attributes = termios()
    tcgetattr(inputFileHandle.fileDescriptor, &attributes)
    attributes.c_iflag &= ~tcflag_t(ICRNL)
    attributes.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(inputFileHandle.fileDescriptor, TCSANOW, &attributes)

    let stdioAttachment = VZFileHandleSerialPortAttachment(fileHandleForReading: inputFileHandle,
                                                           fileHandleForWriting: outputFileHandle)

    consoleConfiguration.attachment = stdioAttachment

    return consoleConfiguration
}

func createMachineIdentifier(machineIdentifierPath: String) -> VZGenericMachineIdentifier {
    let machineIdentifier = VZGenericMachineIdentifier()
    try! machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: machineIdentifierPath))
    return machineIdentifier
}

func getMachineIdentifier(machineIdentifierPath: String) throws -> VZGenericMachineIdentifier {
    guard let machineIdentifierData = try? Data(contentsOf: URL(fileURLWithPath: machineIdentifierPath)) else {
        throw VMError.cannotGetMachineIdentifierData
    }
    
    guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineIdentifierData) else {
        throw VMError.cannotParseMachineIdentifier
    }
    
    return machineIdentifier
}

func createMainDiskImage() throws {
    let diskCreated = FileManager.default.createFile(atPath: mainDiskImagePath, contents: nil, attributes: nil)
    if !diskCreated {
        throw VMError.cannotCreateMainDiskImage
    }

    guard let mainDiskFileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: mainDiskImagePath)) else {
        throw VMError.cannotOpenFileHandleToMainDiskImage
    }

    do {
        try mainDiskFileHandle.truncate(atOffset: 64 * 1024 * 1024 * 1024)
    } catch {
        throw VMError.cannotTruncateMainDiskImage
    }
}

func createBlockDeviceConfiguration(diskImagePath: String) throws -> VZVirtioBlockDeviceConfiguration {
    guard let diskAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: diskImagePath), readOnly: false) else {
        throw VMError.cannotCreateDiskImageAttachment
    }

    return VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
}

func createUSBMassStorageDeviceConfiguration(isoURL: URL) throws -> VZUSBMassStorageDeviceConfiguration {
   guard let intallerDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true) else {
       print("Failed to create usb storage device")
       exit(EXIT_FAILURE)
   }

   return VZUSBMassStorageDeviceConfiguration(attachment: intallerDiskAttachment)
}

func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
    let networkDevice = VZVirtioNetworkDeviceConfiguration()
    networkDevice.attachment = VZNATNetworkDeviceAttachment()

    return networkDevice
}

func printUsageAndExit() -> Never {
    print("Usage: \(CommandLine.arguments[0]) <iso-path>")
    exit(EX_USAGE)
}
