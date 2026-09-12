# Boot log review — 2026-07-03 image

Raw serial-console capture of a full boot, followed by a triage of every
warning and error in it.

**Provenance:** captured from the `console=ttyS0,115200n8` serial console of the
2026-07-03 rootfs (`Linux 6.6.26 ... #1 SMP Fri Jul  3 23:58:34 BST 2026`,
`U-Boot SPL 2023.10 (Jul 03 2026)`).

> **STALE — read the dates before acting on anything here.** This capture
> predates, and therefore does not reflect:
> - the `pwm_fan.v` / `thermal.c` fan-at-boot fix (2026-09-04)
> - the removal of python3/supervisor from the rootfs (see the defconfig
>   comment at `BR2_PACKAGE_PYTHON3`)
> - the swap from the 2.4GHz-only RTL8192EU to the dual-band RTL8811CU
>   (2026-09-13) — the WiFi section below shows the *old* adapter
>
> It is kept as a reference capture of a known-good boot, not as current state.

---

## Raw capture

```
U-Boot SPL 2023.10 (Jul 03 2026 - 23:53:30 +0100)
Trying to boot from MMC1


U-Boot 2023.10 (Jul 03 2026 - 23:53:30 +0100)

CPU:   Altera SoCFPGA Platform
FPGA:  Altera Cyclone V, SE/A6 or SX/C6 or ST/D6, version 0x0
BOOT:  SD/MMC Internal Transceiver (3.0V)
DRAM:  1 GiB
Core:  28 devices, 15 uclasses, devicetree: separate
MMC:   dwmmc0@ff704000: 0
Loading Environment from MMC... *** Warning - bad CRC, using default environment

In:    serial
Out:   serial
Err:   serial
Model: Terasic DE10-Nano
Net:
Error: ethernet@ff702000 address not set.
No ethernet found.

Hit any key to stop autoboot:  0
889 bytes read in 3 ms (289.1 KiB/s)
## Executing script at 01000000
odo-miner boot script
Loading FPGA bitstream...
3229848 bytes read in 165 ms (18.7 MiB/s)
Loading device tree and kernel...
22908 bytes read in 12 ms (1.8 MiB/s)
10969600 bytes read in 568 ms (18.4 MiB/s)
Booting...
Kernel image @ 0x1000000 [ 0x000000 - 0xa76200 ]
## Flattened Device Tree blob at 02000000
   Booting using the fdt blob at 0x2000000
Working FDT set to 2000000
   Loading Device Tree to 09ff7000, end 09fff97b ... OK
Working FDT set to 9ff7000

Starting kernel ...

Deasserting all peripheral resets
[    0.000000] Booting Linux on physical CPU 0x0
[    0.000000] Linux version 6.6.26 (colin@DESKTOP-4QNEMEC) (arm-linux-gcc.br_real (Buildroot 2021.11-18033-g83947c7bb6) 14.3.0, GNU ld (GNU Binutils) 2.43.1) #1 SMP Fri Jul  3 23:58:34 BST 2026
[    0.000000] CPU: ARMv7 Processor [413fc090] revision 0 (ARMv7), cr=10c5387d
[    0.000000] CPU: PIPT / VIPT nonaliasing data cache, VIPT aliasing instruction cache
[    0.000000] OF: fdt: Machine model: QMTECH Cyclone V SoC KFB (odo-miner)
[    0.000000] Memory policy: Data cache writealloc
[    0.000000] efi: UEFI not found.
[    0.000000] cma: Reserved 64 MiB at 0x3c000000 on node -1
[    0.000000] Zone ranges:
[    0.000000]   DMA      [mem 0x0000000000000000-0x000000002fffffff]
[    0.000000]   Normal   empty
[    0.000000]   HighMem  [mem 0x0000000030000000-0x000000003fffffff]
[    0.000000] Movable zone start for each node
[    0.000000] Early memory node ranges
[    0.000000]   node   0: [mem 0x0000000000000000-0x000000003fffffff]
[    0.000000] Initmem setup node 0 [mem 0x0000000000000000-0x000000003fffffff]
[    0.000000] percpu: Embedded 16 pages/cpu s36180 r8192 d21164 u65536
[    0.000000] Kernel command line: root=/dev/mmcblk0p2 rw rootwait console=ttyS0,115200n8 consoleblank=0 uio_pdrv_genirq.of_id=generic-uio
[    0.000000] Dentry cache hash table entries: 131072 (order: 7, 524288 bytes, linear)
[    0.000000] Inode-cache hash table entries: 65536 (order: 6, 262144 bytes, linear)
[    0.000000] Built 1 zonelists, mobility grouping on.  Total pages: 260608
[    0.000000] mem auto-init: stack:all(zero), heap alloc:off, heap free:off
[    0.000000] Memory: 946336K/1048576K available (15360K kernel code, 2473K rwdata, 6492K rodata, 2048K init, 419K bss, 36704K reserved, 65536K cma-reserved, 196608K highmem)
[    0.000000] SLUB: HWalign=64, Order=0-3, MinObjects=0, CPUs=2, Nodes=1
[    0.000000] trace event string verifier disabled
[    0.000000] rcu: Hierarchical RCU implementation.
[    0.000000] rcu:     RCU event tracing is enabled.
[    0.000000] rcu:     RCU restricting CPUs from NR_CPUS=16 to nr_cpu_ids=2.
[    0.000000] rcu: RCU calculated value of scheduler-enlistment delay is 10 jiffies.
[    0.000000] rcu: Adjusting geometry for rcu_fanout_leaf=16, nr_cpu_ids=2
[    0.000000] NR_IRQS: 16, nr_irqs: 16, preallocated irqs: 16
[    0.000000] L2C-310 erratum 769419 enabled
[    0.000000] L2C-310 enabling early BRESP for Cortex-A9
[    0.000000] L2C-310 full line of zeros enabled for Cortex-A9
[    0.000000] L2C-310 ID prefetch enabled, offset 8 lines
[    0.000000] L2C-310 dynamic clock gating enabled, standby mode enabled
[    0.000000] L2C-310 cache controller enabled, 8 ways, 512 kB
[    0.000000] L2C-310: CACHE_ID 0x410030c9, AUX_CTRL 0x76460001
[    0.000000] rcu: srcu_init: Setting srcu_struct sizes based on contention.
[    0.000000] clocksource: timer1: mask: 0xffffffff max_cycles: 0xffffffff, max_idle_ns: 19112604467 ns
[    0.000000] sched_clock: 32 bits at 100MHz, resolution 10ns, wraps every 21474836475ns
[    0.000015] Switching to timer-based delay loop, resolution 10ns
[    0.000958] Console: colour dummy device 80x30
[    0.001010] Calibrating delay loop (skipped), value calculated using timer frequency.. 200.00 BogoMIPS (lpj=1000000)
[    0.001025] CPU: Testing write buffer coherency: ok
[    0.001061] CPU0: Spectre v2: using BPIALL workaround
[    0.001069] pid_max: default: 32768 minimum: 301
[    0.001192] Mount-cache hash table entries: 2048 (order: 1, 8192 bytes, linear)
[    0.001207] Mountpoint-cache hash table entries: 2048 (order: 1, 8192 bytes, linear)
[    0.001948] CPU0: thread -1, cpu 0, socket 0, mpidr 80000000
[    0.003076] Setting up static identity map for 0x300000 - 0x3000ac
[    0.004181] rcu: Hierarchical SRCU implementation.
[    0.004188] rcu:     Max phase no-delay instances is 1000.
[    0.006658] EFI services will not be available.
[    0.006891] smp: Bringing up secondary CPUs ...
[    0.007709] CPU1: thread -1, cpu 1, socket 0, mpidr 80000001
[    0.007727] CPU1: Spectre v2: using BPIALL workaround
[    0.007873] smp: Brought up 1 node, 2 CPUs
[    0.007886] SMP: Total of 2 processors activated (400.00 BogoMIPS).
[    0.007896] CPU: All CPU(s) started in SVC mode.
[    0.008703] devtmpfs: initialized
[    0.013365] VFP support v0.3: implementor 41 architecture 3 part 30 variant 9 rev 4
[    0.013605] clocksource: jiffies: mask: 0xffffffff max_cycles: 0xffffffff, max_idle_ns: 19112604462750000 ns
[    0.013626] futex hash table entries: 512 (order: 3, 32768 bytes, linear)
[    0.016335] pinctrl core: initialized pinctrl subsystem
[    0.018786] DMI not present or invalid.
[    0.019494] NET: Registered PF_NETLINK/PF_ROUTE protocol family
[    0.022320] DMA: preallocated 256 KiB pool for atomic coherent allocations
[    0.024708] thermal_sys: Registered thermal governor 'step_wise'
[    0.024790] cpuidle: using governor menu
[    0.025092] No ATAGs?
[    0.025186] hw-breakpoint: found 5 (+1 reserved) breakpoint and 1 watchpoint registers.
[    0.025197] hw-breakpoint: maximum watchpoint size is 4 bytes.
[    0.027831] Serial: AMBA PL011 UART driver
[    0.064961] iommu: Default domain type: Translated
[    0.064973] iommu: DMA domain TLB invalidation policy: strict mode
[    0.065865] SCSI subsystem initialized
[    0.066446] usbcore: registered new interface driver usbfs
[    0.066484] usbcore: registered new interface driver hub
[    0.066529] usbcore: registered new device driver usb
[    0.066803] usb_phy_generic soc:usbphy: dummy supplies not allowed for exclusive requests
[    0.068125] pps_core: LinuxPPS API ver. 1 registered
[    0.068134] pps_core: Software ver. 5.3.6 - Copyright 2005-2007 Rodolfo Giometti <giometti@linux.it>
[    0.068154] PTP clock support registered
[    0.068359] EDAC MC: Ver: 3.0.0
[    0.069703] scmi_core: SCMI protocol bus registered
[    0.070696] FPGA manager framework
[    0.072347] vgaarb: loaded
[    0.072881] clocksource: Switched to clocksource timer1
[    0.087332] NET: Registered PF_INET protocol family
[    0.087560] IP idents hash table entries: 16384 (order: 5, 131072 bytes, linear)
[    0.089336] tcp_listen_portaddr_hash hash table entries: 512 (order: 0, 4096 bytes, linear)
[    0.089366] Table-perturb hash table entries: 65536 (order: 6, 262144 bytes, linear)
[    0.089379] TCP established hash table entries: 8192 (order: 3, 32768 bytes, linear)
[    0.089456] TCP bind hash table entries: 8192 (order: 5, 131072 bytes, linear)
[    0.089687] TCP: Hash tables configured (established 8192 bind 8192)
[    0.089809] UDP hash table entries: 512 (order: 2, 16384 bytes, linear)
[    0.089855] UDP-Lite hash table entries: 512 (order: 2, 16384 bytes, linear)
[    0.090038] NET: Registered PF_UNIX/PF_LOCAL protocol family
[    0.090795] RPC: Registered named UNIX socket transport module.
[    0.090807] RPC: Registered udp transport module.
[    0.090812] RPC: Registered tcp transport module.
[    0.090816] RPC: Registered tcp-with-tls transport module.
[    0.090820] RPC: Registered tcp NFSv4.1 backchannel transport module.
[    0.090835] PCI: CLS 0 bytes, default 64
[    0.091731] hw perfevents: enabled with armv7_cortex_a9 PMU driver, 7 counters available
[    0.093106] Initialise system trusted keyrings
[    0.093578] workingset: timestamp_bits=30 max_order=18 bucket_order=0
[    0.093928] squashfs: version 4.0 (2009/01/31) Phillip Lougher
[    0.094272] NFS: Registering the id_resolver key type
[    0.094312] Key type id_resolver registered
[    0.094318] Key type id_legacy registered
[    0.094346] nfs4filelayout_init: NFSv4 File Layout Driver Registering...
[    0.094354] nfs4flexfilelayout_init: NFSv4 Flexfile Layout Driver Registering...
[    0.094388] ntfs: driver 2.1.32 [Flags: R/O].
[    0.094726] Key type asymmetric registered
[    0.094737] Asymmetric key parser 'x509' registered
[    0.094820] bounce: pool size: 64 pages
[    0.094872] Block layer SCSI generic (bsg) driver version 0.4 loaded (major 246)
[    0.094882] io scheduler mq-deadline registered
[    0.094888] io scheduler kyber registered
[    0.094914] io scheduler bfq registered
[    0.193940] Serial: 8250/16550 driver, 5 ports, IRQ sharing enabled
[    0.197625] printk: console [ttyS0] disabled
[    0.198014] ffc02000.serial: ttyS0 at MMIO 0xffc02000 (irq = 31, base_baud = 6250000) is a 16550A
[    0.198063] printk: console [ttyS0] enabled
[    0.938942] ffc03000.serial: ttyS1 at MMIO 0xffc03000 (irq = 32, base_baud = 6250000) is a 16550A
[    0.949768] SuperH (H)SCI(F) driver initialized
[    0.955184] msm_serial: driver initialized
[    0.959271] STMicroelectronics ASC driver initialized
[    0.965373] STM32 USART driver initialized
[    0.984747] brd: module loaded
[    0.993692] loop: module loaded
[    1.002689] spi_altera ff201000.spi: error -ENXIO: IRQ index 0 not found
[    1.010033] spi_altera ff201000.spi: regoff 0, irq -6
[    1.015349] spi_altera ff201100.spi: error -ENXIO: IRQ index 0 not found
[    1.022893] spi_altera ff201100.spi: regoff 0, irq -6
[    1.034344] CAN device driver interface
[    1.039172] bgmac_bcma: Broadcom 47xx GBit MAC driver loaded
[    1.045936] e1000e: Intel(R) PRO/1000 Network Driver
[    1.050887] e1000e: Copyright(c) 1999 - 2015 Intel Corporation.
[    1.056838] igb: Intel(R) Gigabit Ethernet Network Driver
[    1.062217] igb: Copyright (c) 2007-2014 Intel Corporation.
[    1.070018] socfpga-dwmac ff702000.ethernet: IRQ eth_wake_irq not found
[    1.076668] socfpga-dwmac ff702000.ethernet: IRQ eth_lpi not found
[    1.082975] socfpga-dwmac ff702000.ethernet: PTP uses main clock
[    1.088980] socfpga-dwmac ff702000.ethernet: No sysmgr-syscon node found
[    1.095688] socfpga-dwmac ff702000.ethernet: Unable to parse OF data
[    1.102024] socfpga-dwmac: probe of ff702000.ethernet failed with error -524
[    1.112467] stmmaceth ff702000.ethernet: IRQ eth_wake_irq not found
[    1.118792] stmmaceth ff702000.ethernet: IRQ eth_lpi not found
[    1.124755] stmmaceth ff702000.ethernet: PTP uses main clock
[    1.130771] stmmaceth ff702000.ethernet: User ID: 0x10, Synopsys ID: 0x37
[    1.137582] stmmaceth ff702000.ethernet:     DWMAC1000
[    1.142447] stmmaceth ff702000.ethernet: DMA HW capability register supported
[    1.149570] stmmaceth ff702000.ethernet: RX Checksum Offload Engine supported
[    1.156698] stmmaceth ff702000.ethernet: COE Type 2
[    1.161560] stmmaceth ff702000.ethernet: TX Checksum insertion supported
[    1.168249] stmmaceth ff702000.ethernet: Enhanced/Alternate descriptors
[    1.174850] stmmaceth ff702000.ethernet: Enabled extended descriptors
[    1.181267] stmmaceth ff702000.ethernet: Ring mode enabled
[    1.186751] stmmaceth ff702000.ethernet: Enable RX Mitigation via HW Watchdog Timer
[    1.203868] Micrel KSZ9031 Gigabit PHY stmmac-0:01: attached PHY driver (mii_bus:phy_addr=stmmac-0:01, irq=POLL)
[    1.216116] pegasus: Pegasus/Pegasus II USB Ethernet driver
[    1.221715] usbcore: registered new interface driver pegasus
[    1.227441] usbcore: registered new interface driver asix
[    1.232870] usbcore: registered new interface driver ax88179_178a
[    1.238985] usbcore: registered new interface driver cdc_ether
[    1.244863] usbcore: registered new interface driver smsc75xx
[    1.250618] usbcore: registered new interface driver smsc95xx
[    1.256393] usbcore: registered new interface driver net1080
[    1.262059] usbcore: registered new interface driver cdc_subset
[    1.268013] usbcore: registered new interface driver zaurus
[    1.273634] usbcore: registered new interface driver cdc_ncm
[    1.281928] dwc2 ffb40000.usb: supply vusb_d not found, using dummy regulator
[    1.289251] dwc2 ffb40000.usb: supply vusb_a not found, using dummy regulator
[    1.296711] dwc2 ffb40000.usb: EPs: 16, dedicated fifos, 8064 entries in SPRAM
[    1.304498] dwc2 ffb40000.usb: DWC OTG Controller
[    1.309218] dwc2 ffb40000.usb: new USB bus registered, assigned bus number 1
[    1.316306] dwc2 ffb40000.usb: irq 35, io mem 0xffb40000
[    1.322429] hub 1-0:1.0: USB hub found
[    1.326248] hub 1-0:1.0: 1 port detected
[    1.333303] usbcore: registered new interface driver usb-storage
[    1.341440] SPI driver ads7846 has no spi_device_id for ti,tsc2046
[    1.347634] SPI driver ads7846 has no spi_device_id for ti,ads7843
[    1.353809] SPI driver ads7846 has no spi_device_id for ti,ads7845
[    1.359965] SPI driver ads7846 has no spi_device_id for ti,ads7873
[    1.366903] ads7846 spi1.0: touchscreen, irq 36
[    1.371806] input: ADS7846 Touchscreen as /devices/platform/soc/ff201100.spi/spi_master/spi1/spi1.0/input/input0
[    1.385318] i2c_dev: i2c /dev entries driver
[    1.404875] sdhci: Secure Digital Host Controller Interface driver
[    1.411043] sdhci: Copyright(c) Pierre Ossman
[    1.417170] Synopsys Designware Multimedia Card Interface Driver
[    1.424810] sdhci-pltfm: SDHCI platform and OF driver helper
[    1.433408] ledtrig-cpu: registered to indicate activity on CPUs
[    1.441435] usbcore: registered new interface driver usbhid
[    1.447054] usbhid: USB HID core driver
[    1.451754] fb_ili9341 spi0.0: fbtft_property_value: buswidth = 8
[    1.457878] fb_ili9341 spi0.0: fbtft_property_value: rotate = 270
[    1.463972] fb_ili9341 spi0.0: fbtft_property_value: fps = 30
[    2.084059] Console: switching to colour frame buffer device 40x30
[    2.090814] graphics fb0: fb_ili9341 frame buffer, 320x240, 150 KiB video memory, 16 KiB buffer memory, fps=33, spi0.0 at 25 MHz
[    2.108622] NET: Registered PF_INET6 protocol family
[    2.114847] Segment Routing with IPv6
[    2.118562] In-situ OAM (IOAM) with IPv6
[    2.122555] sit: IPv6, IPv4 and MPLS over IPv4 tunneling driver
[    2.129142] NET: Registered PF_PACKET protocol family
[    2.134211] can: controller area network core
[    2.138598] NET: Registered PF_CAN protocol family
[    2.143403] can: raw protocol
[    2.146369] can: broadcast manager protocol
[    2.150543] can: netlink gateway - max_hops=1
[    2.155353] Key type dns_resolver registered
[    2.159817] ThumbEE CPU extension supported.
[    2.164122] Registering SWP/SWPB emulation handler
[    2.242998] Loading compiled-in X.509 certificates
[    2.260158] at24 0-0051: supply vcc not found, using dummy regulator
[    2.298447] rtc-ds1307: probe of 0-0068 failed with error -121
[    2.305072] of-fpga-region soc:base_fpga_region: FPGA Region probed
[    2.531506] usb 1-1: new high-speed USB device number 2 using dwc2
[    2.533465] dma-pl330 ffe01000.pdma: Loaded driver for PL330 DMAC-341330
[    2.544459] dma-pl330 ffe01000.pdma:         DBUFF-512x8bytes Num_Chans-8 Num_Peri-32 Num_Events-8
[    2.560206] dw_mmc ff704000.mmc: clk-phase-sd-hs was specified, but failed to find altr,sys-mgr regmap!
[    2.569638] dw_mmc ff704000.mmc: IDMAC supports 32-bit address mode.
[    2.577068] genirq: Setting trigger mode 3 for irq 52 failed (altera_gpio_irq_set_type+0x0/0x74)
[    2.583019] dw_mmc ff704000.mmc: Using internal DMA controller.
[    2.585901] gpio-keys gpio-keys: Unable to claim irq 52; error -22
[    2.591747] dw_mmc ff704000.mmc: Version ID is 240a
[    2.597909] gpio-keys: probe of gpio-keys failed with error -22
[    2.598220] clk: Disabling unused clocks
[    2.602832] dw_mmc ff704000.mmc: DW MMC controller at irq 51,32 bit host data width,1024 deep fifo
[    2.621900] dw_mmc ff704000.mmc: Got CD GPIO
[    2.621918] dw-apb-uart ffc02000.serial: forbid DMA for kernel console
[    2.626258] mmc_host mmc0: card is polling.
[    2.649607] mmc_host mmc0: Bus speed (slot 0) = 50000000Hz (slot req 400000Hz, actual 396825HZ div = 63)
[    2.671877] Waiting for root device /dev/mmcblk0p2...
[    2.711519] mmc_host mmc0: Bus speed (slot 0) = 50000000Hz (slot req 50000000Hz, actual 50000000HZ div = 0)
[    2.721375] mmc0: new high speed SDHC card at address 0001
[    2.727592] mmcblk0: mmc0:0001 SD 14.6 GiB
[    2.735819]  mmcblk0: p1 p2 p3
[    3.399817] EXT4-fs (mmcblk0p2): recovery complete
[    3.407106] EXT4-fs (mmcblk0p2): mounted filesystem 41baa9f5-52db-48b3-8cb5-567076d2b522 r/w with ordered data mode. Quota mode: disabled.
[    3.419591] VFS: Mounted root (ext4 filesystem) on device 179:2.
[    3.428220] devtmpfs: mounted
[    3.433633] Freeing unused kernel image (initmem) memory: 2048K
[    3.440176] Run /sbin/init as init process
[    3.672933] EXT4-fs (mmcblk0p2): re-mounted 41baa9f5-52db-48b3-8cb5-567076d2b522 r/w. Quota mode: disabled.
Seeding 256 bits and crediting[    3.898566] random: crng init done

Saving 256 bits of creditable seed for next boot
Starting syslogd: OK
Starting klogd: OK
Running sysctl: OK
Starting watchdog: OK
Starting network: ifup: can't open '/var/run/ifstate.new': No such file or directory
FAIL
Starting dhcpcd...
main: mkdir: /var/run/dhcpcd: No such file or directory
main: pidfile_lock: /var/run/dhcpcd/pid: No such file or directory
Starting WiFi: [    5.094262] cfg80211: Loading compiled-in X.509 certificates for regulatory database
[    5.248850] Loaded X.509 cert 'sforshee: 00b28ddf47aef9cea7'
[    5.256754] Loaded X.509 cert 'wens: 61c038651aabdcf94bd0ac7ff06c7248db18c600'
[    5.266825] platform regulatory.0: Direct firmware load for regulatory.db failed with error -2
[    5.275457] cfg80211: failed to load regulatory.db
[    5.516431] usb 1-1: RTL8192EU rev B (SMIC) romver 0, 2T2R, TX queues 3, WiFi=1, BT=0, GPS=0, HI PA=0
[    5.525661] usb 1-1: RTL8192EU MAC: fc:22:1c:30:c7:76
[    5.530701] usb 1-1: rtl8xxxu: Loading firmware rtlwifi/rtl8192eu_nic.bin
[    5.542143] usb 1-1: Firmware revision 35.7 (signature 0x92e1)
[    6.585370] usbcore: registered new interface driver rtl8xxxu
Successfully initialized wpa_supplicant
[    8.283926] wlan0: authenticate with 94:f7:be:ea:f3:34
[    8.297905] wlan0: send auth to 94:f7:be:ea:f3:34 (try 1/3)
[    8.312335] wlan0: authenticated
[    8.322913] wlan0: associate with 94:f7:be:ea:f3:34 (try 1/3)
[    8.509983] wlan0: RX AssocResp from 94:f7:be:ea:f3:34 (capab=0x1411 status=0 aid=48)
[    8.519188] usb 1-1: rtl8xxxu_bss_info_changed: HT supported
[    8.527231] wlan0: associated
[    8.906110] cryptd: max_cpu_qlen set to 1000
OK
Starting ntpd: OK
Starting crond: OK
Starting sshd: /etc/ssh/sshd_config line 11: Unsupported option UsePAM
OK
Starting watchdog: OK
Starting odo-miner: OK (odo-miner-pipe-uio)
Installing epoch-update crontab: OK
Starting odo-ui: OK
Starting odo-webd: OK (http://<board-ip>:80)
Starting supervisord: /usr/lib/python3.13/site-packages/supervisor/options.py:13: UserWarning: pkg_resources is deprecated as an API. See https://setuptools.pypa.io/en/latest/pkg_resources.html. The pkg_resources package is slated for removal as early as 2025-11-30. Refrain from using this package or pin to Setuptools<81.
/usr/lib/python3.13/site-packages/supervisor/options.py:474: UserWarning: Supervisord is running as root and it is searching for its configuration file in default locations (including its current working directory); you probably want to specify a "-c" argument specifying an absolute path to a configuration file for improved security.
Error: The directory named as part of the path /var/run/supervisord.pid does not exist
For help, use /usr/bin/supervisord -h
done

Welcome to odo-miner (Cyclone V SoC)
buildroot login: [  255.126921] TCP: request_sock_TCP: Possible SYN flooding on port 0.0.0.0:80. Dropping request.
```

---

## Triage

The board boots to a usable state: bitstream loads, both CPUs come up, rootfs
mounts, and the miner/UI/web stack starts. Everything below is about the noise
around that, ranked by whether it actually matters *on this board*.

### Not problems — deliberate, and do not "fix" them

**U-Boot reports `Model: Terasic DE10-Nano`, Linux reports `QMTECH Cyclone V SoC KFB`.**
This is intentional and load-bearing, not a mismatch to be corrected. The QMTECH
board is DE10-Nano ball-/MiSTer-compatible, and `BR2_TARGET_UBOOT_BOARD_DEFCONFIG="socfpga_de10_nano"`
is what supplies the matching DDR3/pinmux/PLL/IOCSR settings. The
"obviously correct" `socfpga_cyclone5` SoCDK defconfig produces a **silent
board**. See the comment at that defconfig line and `docs/BOARD_REFERENCE.md`.
Changing this to make the strings agree will brick the boot.

**`supervisord` fails on `/var/run/supervisord.pid`.**
Stale cruft, nothing depends on it. Process supervision here is BusyBox
`init.d` (`S90odod`, `S10watchdog`, ...), never a supervisor daemon — see
`docs/DEPLOYMENT.md` and `docs/BUILD_LINUX.md`. python3 + supervisor have since
been dropped from the defconfig entirely (~30 MB of rootfs with it), so this
message disappears on the next image build. Zero operational impact.

**`gpio-keys` fails to claim irq 52.**
The reset button does not use `gpio-keys`. It is polled via `pio_thermal` bit2
in `hps/thermal.c` (J10 pin 36/AE20, active-low, ~2 s hold). This probe failing
costs nothing.

**Dummy regulators, `efi: UEFI not found`, `No ATAGs?`, `DMI not present`,
`forbid DMA for kernel console`, SPI `-ENXIO: IRQ index 0 not found`.**
Normal for this platform/DTS. The SPI IRQs are genuinely absent from the DTS and
the display + touchscreen run polled regardless — both demonstrably work.

### Real, and worth acting on

**1. `cfg80211: failed to load regulatory.db` — now the most actionable item.**
`iw reg get` confirms the fallback: `country 00: DFS-UNSET`. This mattered
little when the adapter was 2.4GHz-only, but the board now runs a **dual-band
RTL8811CU**, and 5 GHz channel availability and TX power are regulatory-gated.
Current operation on ch36 (5180 MHz, UNII-1) is fine, but DFS and upper-band
channels stay restricted, and a router-side 5 GHz channel change could drop the
link. Fix is to ship the regdb (`linux-firmware` regulatory database) in the
rootfs.

**2. `/var/run` runtime-path failures — blocks the Ethernet path specifically.**
```
Starting network: ifup: can't open '/var/run/ifstate.new': No such file or directory
main: mkdir: /var/run/dhcpcd: No such file or directory
```
Harmless *for WiFi*: `S45wifi` ignores both, running its own `wpa_supplicant`
and busybox `udhcpc` (its header comment notes dhcpcd is not in the image —
something is still trying to start it anyway, which is the cruft to remove).

But `ifup` failing means `/etc/network/interfaces` is not usable as written, so
**this must be fixed before wired Ethernet can be brought up** — which is the
standing recommendation if a cable can reach the board, since it removes the
WiFi-contention failure class that cost two epoch boundaries. `eth0` exists and
the Micrel KSZ9031 PHY attaches cleanly, so the hardware side is ready.

**3. RTC absent — `rtc-ds1307: probe of 0-0068 failed with error -121`.**
Confirmed by observation, not just the log: after a reboot the clock reads
1970-era until `ntpd` syncs, and files written in that window carry bogus
timestamps. Everything time-sensitive (share timestamps, epoch-boundary
comparisons, log correlation) depends on NTP reaching the network first. On a
board whose network has been the weak link, that ordering is worth remembering.

**4. `EXT4-fs (mmcblk0p2): recovery complete`.**
Journal replay from an unclean shutdown. Expected given this board's brownout /
boot-loop history, and benign in itself — but it is the fingerprint of power
being cut mid-write, so if it appears on *every* boot, that is worth chasing.

### Cosmetic

**`sshd_config line 11: Unsupported option UsePAM`** — this OpenSSH build has no
PAM; sshd starts fine. Drop the line.

**`TCP: request_sock_TCP: Possible SYN flooding on port 0.0.0.0:80`** — `odo-webd`
is single-threaded with a small backlog, so a dashboard refresh burst or a LAN
scan triggers this. It operates on a trusted-LAN model (`docs/`), so on a
LAN-only board this is noise rather than an attack signal.

### U-Boot items

**`Warning - bad CRC, using default environment`** — no saved environment; boot
is driven entirely by `boot.scr`, which does not depend on stored env. Benign.

**`Error: ethernet@ff702000 address not set. / No ethernet found.`** — U-Boot has
no MAC, so U-Boot-level networking (netboot/tftp) is unavailable. Linux brings
the same controller up independently via `stmmaceth` with a locally-administered
placeholder MAC (`02:de:ad:be:ef:01`). Only matters if bootloader networking is
ever wanted; note the placeholder MAC is what a DHCP reservation would key on.

**`socfpga-dwmac ... probe failed with error -524`, then `stmmaceth ... DWMAC1000`
attaches.** The SoCFPGA glue driver declines, the generic stmmac driver binds and
the PHY attaches. Net result is a working interface; the failing line is noise.
