#import <Virtualization/Virtualization.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <dispatch/dispatch.h>

typedef struct VZWrapper {
    VZVirtualMachineConfiguration *config;
    VZVirtualMachine *vm;
    dispatch_queue_t vm_queue;
    int to_vm_fd;
    int from_vm_fd;
    dispatch_semaphore_t started_sem;
    dispatch_semaphore_t stopped_sem;
    dispatch_semaphore_t done_sem;
    int last_result;
    int running;
    int finalized;
} VZWrapper;

@interface VZStateObserver : NSObject <VZVirtualMachineDelegate>
@property (nonatomic, weak) VZVirtualMachine *vm;
@property (nonatomic, assign) dispatch_semaphore_t started_sem;
@property (nonatomic, assign) dispatch_semaphore_t stopped_sem;
@end
@implementation VZStateObserver
- (void)virtualMachine:(VZVirtualMachine *)vm didStopWithError:(NSError *)error {
    NSLog(@"VM didStop: %@", error.localizedDescription);
    if (self.stopped_sem) dispatch_semaphore_signal(self.stopped_sem);
}
- (void)guestDidStopVirtualMachine:(VZVirtualMachine *)vm {
    if (self.stopped_sem) dispatch_semaphore_signal(self.stopped_sem);
}
@end

int vz_available(void) {
    @autoreleasepool {
        return [VZVirtualMachine respondsToSelector:@selector(class)] ? 1 : 0;
    }
}

// ---- EFI boot mode ----
// Boots from an EFI application on a FAT32 ESP disk image.
// Kernel cmdline is set via EFI boot loader arguments.

VZWrapper *vz_create_efi(
    uint64_t ram_bytes,
    unsigned int cpu_count,
    const char *esp_disk_path,
    const char *boot_args,
    const char *rootfs_disk_path,
    int *out_to_vm_fd,
    int *out_from_vm_fd)
{
    @autoreleasepool {
        VZWrapper *w = calloc(1, sizeof(VZWrapper));
        if (!w) return NULL;

        // EFI variable store (required by VZEFIBootLoader)
        NSError *varErr = nil;
        NSURL *varURL = [NSURL fileURLWithPath:
            [NSString stringWithFormat:@"%s/efi_vars.ndbm", 
             getenv("TMPDIR") ?: "/tmp"]];
        VZEFIVariableStore *varStore =
            [[VZEFIVariableStore alloc] initCreatingVariableStoreAtURL:varURL
                                                               options:VZEFIVariableStoreInitializationOptionAllowOverwrite
                                                                 error:&varErr];
        if (!varStore) {
            NSLog(@"vz: EFI var store error: %@", varErr.localizedDescription);
            free(w);
            return NULL;
        }

        // EFI boot loader pointing to the ESP disk
        VZEFIBootLoader *bootLoader = [[VZEFIBootLoader alloc] init];
        bootLoader.variableStore = varStore;
        // Config
        w->config = [[VZVirtualMachineConfiguration alloc] init];
        w->config.bootLoader = bootLoader;
        w->config.memorySize = ram_bytes;
        w->config.CPUCount = cpu_count;

        // Generic platform (required for EFI boot)
        w->config.platform = [[VZGenericPlatformConfiguration alloc] init];
        // ESP disk (virtio-blk, read-only)
        if (esp_disk_path && esp_disk_path[0]) {
            NSURL *espURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:esp_disk_path]];
            NSError *espErr = nil;
            VZDiskImageStorageDeviceAttachment *espAtt =
                [[VZDiskImageStorageDeviceAttachment alloc]
                    initWithURL:espURL readOnly:YES error:&espErr];
            if (espAtt) {
                VZVirtioBlockDeviceConfiguration *espBlock =
                    [[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:espAtt];
                w->config.storageDevices = @[espBlock];
            } else {
                NSLog(@"vz: ESP disk error: %@", espErr.localizedDescription);
            }
        }

        // Optional rootfs disk (second virtio-blk)
        if (rootfs_disk_path && rootfs_disk_path[0]) {
            NSURL *rootURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:rootfs_disk_path]];
            NSError *rootErr = nil;
            VZDiskImageStorageDeviceAttachment *rootAtt =
                [[VZDiskImageStorageDeviceAttachment alloc]
                    initWithURL:rootURL readOnly:YES error:&rootErr];
            if (rootAtt) {
                VZVirtioBlockDeviceConfiguration *rootBlock =
                    [[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:rootAtt];
                NSMutableArray *devices = [w->config.storageDevices mutableCopy] ?: [NSMutableArray array];
                [devices addObject:rootBlock];
                w->config.storageDevices = devices;
            }
        }

        // Serial console
        int to_vm[2], from_vm[2];
        if (pipe(to_vm) != 0 || pipe(from_vm) != 0) { free(w); return NULL; }
        NSFileHandle *vm_reads  = [[NSFileHandle alloc] initWithFileDescriptor:to_vm[0] closeOnDealloc:YES];
        NSFileHandle *vm_writes = [[NSFileHandle alloc] initWithFileDescriptor:from_vm[1] closeOnDealloc:YES];
        VZFileHandleSerialPortAttachment *serialAtt =
            [[VZFileHandleSerialPortAttachment alloc]
                initWithFileHandleForReading:vm_reads fileHandleForWriting:vm_writes];
        VZVirtioConsoleDeviceSerialPortConfiguration *serialCfg =
            [[VZVirtioConsoleDeviceSerialPortConfiguration alloc] init];
        serialCfg.attachment = serialAtt;
        w->config.serialPorts = @[serialCfg];
        w->to_vm_fd   = to_vm[1];
        w->from_vm_fd = from_vm[0];

        // Entropy
        VZVirtioEntropyDeviceConfiguration *entropy =
            [[VZVirtioEntropyDeviceConfiguration alloc] init];
        w->config.entropyDevices = @[entropy];

        // Validate
        NSError *err = nil;
        if (![w->config validateWithError:&err]) {
            NSLog(@"vz: config error: %@", err.localizedDescription);
            close(w->to_vm_fd); close(w->from_vm_fd);
            free(w); return NULL;
        }

        // Create VM
        w->vm_queue = dispatch_queue_create("com.nullclaw.vz", DISPATCH_QUEUE_SERIAL);
        w->vm = [[VZVirtualMachine alloc] initWithConfiguration:w->config queue:w->vm_queue];
        w->started_sem = dispatch_semaphore_create(0);
        w->stopped_sem = dispatch_semaphore_create(0);
        w->done_sem = dispatch_semaphore_create(0);
        VZStateObserver *obs = [[VZStateObserver alloc] init];
        obs.vm = w->vm;
        obs.started_sem = w->started_sem;
        obs.stopped_sem = w->stopped_sem;
        w->vm.delegate = obs;

        if (out_to_vm_fd)  *out_to_vm_fd  = w->to_vm_fd;
        if (out_from_vm_fd) *out_from_vm_fd = w->from_vm_fd;
        return w;
    }
}

// ---- Direct kernel boot mode (raw ARM64 Image, no EFI) ----

VZWrapper *vz_create(
    uint64_t ram_bytes,
    unsigned int cpu_count,
    const char *kernel_path,
    const char *initrd_path,
    const char *cmdline,
    const char *disk_path,
    int *out_to_vm_fd,
    int *out_from_vm_fd)
{
    @autoreleasepool {
        if (!kernel_path) return NULL;
        VZWrapper *w = calloc(1, sizeof(VZWrapper));
        if (!w) return NULL;

        NSURL *kernelURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:kernel_path]];
        VZLinuxBootLoader *bootLoader = [[VZLinuxBootLoader alloc] initWithKernelURL:kernelURL];
        if (initrd_path && initrd_path[0])
            bootLoader.initialRamdiskURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:initrd_path]];
        if (cmdline && cmdline[0])
            bootLoader.commandLine = [NSString stringWithUTF8String:cmdline];

        w->config = [[VZVirtualMachineConfiguration alloc] init];
        w->config.bootLoader = bootLoader;
        w->config.memorySize = ram_bytes;
        w->config.CPUCount = cpu_count;

        // Generic platform (required for EFI boot)
        w->config.platform = [[VZGenericPlatformConfiguration alloc] init];
        int to_vm[2], from_vm[2];
        if (pipe(to_vm) != 0 || pipe(from_vm) != 0) { free(w); return NULL; }
        NSFileHandle *vm_reads  = [[NSFileHandle alloc] initWithFileDescriptor:to_vm[0] closeOnDealloc:YES];
        NSFileHandle *vm_writes = [[NSFileHandle alloc] initWithFileDescriptor:from_vm[1] closeOnDealloc:YES];
        VZFileHandleSerialPortAttachment *serialAtt =
            [[VZFileHandleSerialPortAttachment alloc]
                initWithFileHandleForReading:vm_reads fileHandleForWriting:vm_writes];
        VZVirtioConsoleDeviceSerialPortConfiguration *serialCfg =
            [[VZVirtioConsoleDeviceSerialPortConfiguration alloc] init];
        serialCfg.attachment = serialAtt;
        w->config.serialPorts = @[serialCfg];
        w->to_vm_fd   = to_vm[1];
        w->from_vm_fd = from_vm[0];

        if (disk_path && disk_path[0]) {
            NSURL *diskURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:disk_path]];
            NSError *diskErr = nil;
            VZDiskImageStorageDeviceAttachment *diskAtt =
                [[VZDiskImageStorageDeviceAttachment alloc]
                    initWithURL:diskURL readOnly:YES error:&diskErr];
            if (diskAtt) {
                VZVirtioBlockDeviceConfiguration *blockCfg =
                    [[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:diskAtt];
                w->config.storageDevices = @[blockCfg];
            }
        }
        VZVirtioEntropyDeviceConfiguration *entropy =
            [[VZVirtioEntropyDeviceConfiguration alloc] init];
        w->config.entropyDevices = @[entropy];

        NSError *err = nil;
        if (![w->config validateWithError:&err]) {
            NSLog(@"vz: config error: %@", err.localizedDescription);
            close(w->to_vm_fd); close(w->from_vm_fd);
            free(w); return NULL;
        }

        w->vm_queue = dispatch_queue_create("com.nullclaw.vz", DISPATCH_QUEUE_SERIAL);
        w->vm = [[VZVirtualMachine alloc] initWithConfiguration:w->config queue:w->vm_queue];
        w->started_sem = dispatch_semaphore_create(0);
        w->stopped_sem = dispatch_semaphore_create(0);
        w->done_sem = dispatch_semaphore_create(0);
        VZStateObserver *obs = [[VZStateObserver alloc] init];
        obs.vm = w->vm;
        obs.started_sem = w->started_sem;
        obs.stopped_sem = w->stopped_sem;
        w->vm.delegate = obs;

        if (out_to_vm_fd)  *out_to_vm_fd  = w->to_vm_fd;
        if (out_from_vm_fd) *out_from_vm_fd = w->from_vm_fd;
        return w;
    }
}

// ---- Lifecycle (shared) ----

int vz_start(VZWrapper *w) {
    if (!w || w->running) return -1;
    w->last_result = -1;
    dispatch_sync(w->vm_queue, ^{
        [w->vm startWithCompletionHandler:^(NSError *err) {
            if (err) NSLog(@"vz_start: %@", err.localizedDescription);
            w->last_result = (err == nil) ? 0 : -1;
            dispatch_semaphore_signal(w->started_sem);
            dispatch_semaphore_signal(w->done_sem);
        }];
    });
    dispatch_semaphore_wait(w->done_sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    if (w->last_result == 0 || w->vm.state == VZVirtualMachineStateRunning) {
        w->running = 1; return 0;
    }
    return -1;
}

int vz_stop(VZWrapper *w) {
    if (!w || !w->running) return -1;
    w->last_result = -1;
    dispatch_sync(w->vm_queue, ^{
        [w->vm stopWithCompletionHandler:^(NSError *err) {
            if (err) NSLog(@"vz_stop: %@", err.localizedDescription);
            w->last_result = 0;
            dispatch_semaphore_signal(w->done_sem);
        }];
    });
    dispatch_semaphore_wait(w->done_sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    w->running = 0;
    return w->last_result;
}

int vz_state(VZWrapper *w) {
    if (!w) return -1;
    switch (w->vm.state) {
        case VZVirtualMachineStateStopped: return 0;
        case VZVirtualMachineStateRunning: return 1;
        case VZVirtualMachineStatePaused:  return 2;
        default: return -1;
    }
}

ssize_t vz_read(VZWrapper *w, char *buf, size_t len, int timeout_ms) {
    if (!w || w->from_vm_fd < 0) return -1;
    struct pollfd pfd = { .fd = w->from_vm_fd, .events = POLLIN };
    int ret = poll(&pfd, 1, timeout_ms);
    if (ret <= 0) return ret;
    return (ssize_t)read(w->from_vm_fd, buf, len);
}

ssize_t vz_write(VZWrapper *w, const char *buf, size_t len) {
    if (!w || w->to_vm_fd < 0) return -1;
    return (ssize_t)write(w->to_vm_fd, buf, len);
}

void vz_destroy(VZWrapper *w) {
    if (!w || w->finalized) return;
    w->finalized = 1;
    if (w->running) vz_stop(w);
    if (w->to_vm_fd >= 0)  close(w->to_vm_fd);
    if (w->from_vm_fd >= 0) close(w->from_vm_fd);
    free(w);
}
