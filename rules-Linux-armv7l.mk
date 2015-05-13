S3_TARGET ?=		s3://$(shell whoami)/
KERNEL_URL ?=		http://ports.ubuntu.com/ubuntu-ports/dists/lucid/main/installer-armel/current/images/versatile/netboot/vmlinuz
MKIMAGE_OPTS ?=		-A arm -O linux -T ramdisk -C none -a 0 -e 0 -n initramfs
DEPENDENCIES ?=	\
	/bin/busybox \
	/etc/udhcpc/default.script \
	/lib/arm-linux-gnueabihf/libnss_dns.so.2 \
	/lib/arm-linux-gnueabihf/libnss_files.so.2 \
	/sbin/mkfs.ext4 \
	/sbin/parted \
	/usr/bin/curl \
	/usr/lib/klibc/bin/ipconfig \
	/usr/sbin/ntpdate
DOCKER_DEPENDENCIES ?=	armbuild/initrd-dependencies
CMDLINE ?=		ip=dhcp root=/dev/nbd0 nbd.max_parts=8 boot=local nousb noplymouth
QEMU_OPTIONS ?=		-M versatilepb -cpu cortex-a9 -m 256 -no-reboot
INITRD_DEBUG ?=		0
TARGET = Linux-armv7l
MAKE = make -f rules-$(TARGET).mk
HOST_ARCH ?=		$(shell uname -m)

.PHONY: publish_on_s3 qemu dist dist_do dist_teardown all travis dependencies-shell uInitrd-shell


# Phonies
all:	uInitrd


travis:
	bash -n tree/init tree/shutdown tree/functions tree/boot-*


qemu:
	$(MAKE) qemu-docker-text || $(MAKE) qemu-local-text


qemu-local-text:	vmlinuz initrd-$(TARGET).gz
	qemu-system-arm \
		$(QEMU_OPTIONS) \
		-append "console=ttyAMA0 earlyprink=ttyAMA0 $(CMDLINE) INITRD_DEBUG=$(INITRD_DEBUG)" \
		-kernel ./vmlinuz \
		-initrd ./initrd-$(TARGET).gz \
		-nographic -monitor null


qemu-local-vga:	vmlinuz initrd-$(TARGET).gz
	qemu-system-arm \
		$(QEMU_OPTIONS) \
		-append "$(CMDLINE)  INITRD_DEBUG=$(INITRD_DEBUG)" \
		-kernel ./vmlinuz \
		-initrd ./initrd-$(TARGET).gz \
		-monitor stdio


qemu-docker qemu-docker-text:	vmlinuz initrd-$(TARGET).gz
	cd qemu; -docker-compose kill metadata
	cd qemu; docker-compose run initrd /bin/bash -xc ' \
		qemu-system-arm \
		  -net nic -net user \
		  $(QEMU_OPTIONS) \
		  -append "console=ttyAMA0 earlyprink=ttyAMA0 $(CMDLINE) INITRD_DEBUG=$(INITRD_DEBUG) METADATA_IP=$$METADATA_PORT_80_TCP_ADDR" \
		  -kernel /boot/vmlinuz \
		  -initrd /boot/initrd-$(TARGET).gz \
		  -nographic -monitor null \
		'


qemu-docker-rescue:	metadata_mock/static/minirootfs.tar
	$(MAKE) qemu-docker-text CMDLINE='boot=rescue rescue_image=http://metadata.local/static/$(shell basename $<)'


publish_on_s3:	uInitrd initrd-$(TARGET).gz
	for file in $<; do \
	  s3cmd put --acl-public $$file $(S3_TARGET); \
	done


dist:
	$(MAKE) dist_do || $(MAKE) dist_teardown


dist_do:
	-git branch -D dist-$(TARGET) || true
	git checkout -b dist-$(TARGET)
	-$(MAKE) dependencies-$(TARGET).tar.gz && git add -f dependencies-$(TARGET).tar.gz
	-$(MAKE) uInitrd-$(TARGET) && git add -f uInitrd-$(TARGET) initrd-$(TARGET).gz tree
	git commit -am ":ship: dist"
	git push -u origin dist-$(TARGET) -f
	$(MAKE) dist_teardown


dist_teardown:
	git checkout master


# Files
vmlinuz:
	-rm -f $@ $@.tmp
	wget -O $@.tmp $(KERNEL_URL)
	mv $@.tmp $@


uInitrd:	uInitrd-$(TARGET)


uInitrd-$(TARGET):	initrd-$(TARGET).gz
	$(MAKE) uInitrd-local || $(MAKE) uInitrd-docker
	touch $@


uInitrd-local:	initrd-$(TARGET).gz
	mkimage $(MKIMAGE_OPTS) -d initrd-$(TARGET).gz uInitrd-$(TARGET)


uInitrd-docker:	initrd-$(TARGET).gz
	docker run \
		-it --rm \
		-v $(PWD):/host \
		-w /tmp \
		moul/u-boot-tools \
		/bin/bash -xec \
		' \
		  cp /host/initrd-$(TARGET).gz . && \
		  mkimage -A arm -O linux -T ramdisk -C none -a 0 -e 0 -n initramfs -d ./initrd-$(TARGET).gz ./uInitrd && \
		  cp uInitrd /host/ \
		'


uInitrd-shell: tree
	test $(HOST_ARCH) = armv7l
	docker run \
		-it --rm \
		-v $(PWD)/tree:/chroot \
		-w /tmp \
		armbuild/busybox \
		chroot /chroot /bin/sh


tree/usr/bin/oc-metadata:
	mkdir -p $(shell dirname $@)
	wget https://raw.githubusercontent.com/scaleway/image-tools/master/skeleton-common/usr/local/bin/oc-metadata -O $@
	chmod +x $@


tree/usr/sbin/@xnbd-client.link:	tree/usr/sbin/xnbd-client
	ln -sf $(<:tree%=%) $(@:%.link=%)
	touch $@


tree/bin/sh:	tree/bin/busybox
	ln -s busybox $@


initrd.gz:	initrd-$(TARGET).gz

initrd-$(TARGET).gz:	tree
	cd tree && find . -print0 | cpio --null -o --format=newc | gzip -9 > $(PWD)/$@


tree:	$(addprefix tree/, $(DEPENDENCIES)) $(wildcard tree/*) tree/bin/sh tree/usr/bin/oc-metadata tree/usr/sbin/@xnbd-client.link Makefile tree/usr/sbin/xnbd-client
	find tree \( -name "*~" -or -name ".??*~" -or -name "#*#" -or -name ".#*" \) -delete


tree/usr/sbin/xnbd-client:
	wget https://github.com/aimxhaisse/xnbd-client-static/raw/dist/bin/xnbd-client-static -O $@
	chmod +x $@


$(addprefix tree/, $(DEPENDENCIES)):	dependencies-$(TARGET).tar.gz
	tar -m -C tree/ -xzf $<

dependencies.tar.gz:	dependencies-$(TARGET).tar.gz


dependencies-$(TARGET).tar.gz:	dependencies-$(TARGET)/Dockerfile
	$(MAKE) dependencies-$(TARGET).tar.gz-armhf || $(MAKE) dependencies-$(TARGET).tar.gz-dist
	tar tvzf $@ | grep bin/busybox || rm -f $@
	@test -f $@ || echo $@ is broken
	@test -f $@ || exit 1


dependencies-shell:
	test $(HOST_ARCH) = armv7l
	docker build -q -t $(DOCKER_DEPENDENCIES) ./dependencies-$(TARGET)/
	docker run -it $(DOCKER_DEPENDENCIES) /bin/bash


dependencies-$(TARGET).tar.gz-armhf:
	test $(HOST_ARCH) = armv7l
	docker build -q -t $(DOCKER_DEPENDENCIES) ./dependencies-$(TARGET)/
	docker run -it $(DOCKER_DEPENDENCIES) export-assets $(DEPENDENCIES)
	docker cp `docker ps -lq`:/tmp/dependencies.tar $(PWD)/
	mv dependencies.tar dependencies-$(TARGET).tar
	docker rm `docker ps -lq`
	rm -f dependencies-$(TARGET).tar.gz
	@ls -lah dependencies-$(TARGET).tar
	gzip dependencies-$(TARGET).tar
	@ls -lah dependencies-$(TARGET).tar.gz


dependencies-$(TARGET).tar.gz-dist:
	-git fetch origin
	git checkout origin/dist-$(TARGET) -- dependencies-$(TARGET).tar.gz
	git reset HEAD dependencies-$(TARGET).tar.gz


minirootfs:
	rm -rf $@ $@.tmp export.tar
	docker rm initrd-minirootfs 2>/dev/null || true
	docker run --name initrd-minirootfs --entrypoint /donotexists armbuild/busybox 2>&1 | grep -v "stat /donotexists: no such file" || true
	docker export initrd-minirootfs > export.tar
	docker rm initrd-minirootfs
	mkdir -p $@.tmp
	tar -C $@.tmp -xf export.tar
	rm -f $@.tmp/.dockerenv $@.tmp/.dockerinit
	-chmod 1777 $@.tmp/tmp
	-chmod 755 $@.tmp/etc $@.tmp/usr $@.tmp/usr/local $@.tmp/usr/sbin
	-chmod 555 $@.tmp/sys
	#echo 127.0.1.1       server >> $@.tmp/etc/hosts
	#echo 127.0.0.1       localhost server >> $@.tmp/etc/hosts
	#echo ::1             localhost ip6-localhost ip6-loopback >> $@.tmp/etc/hosts
	#echo ff02::1         ip6-allnodes >> $@.tmp/etc/hosts
	#echo ff02::2         ip6-allrouters >> $@.tmp/etc/hosts
	mv $@.tmp $@


metadata_mock/static/minirootfs.tar:	minirootfs.tar
	mkdir -p $(shell dirname $@)
	cp $< $@


minirootfs.tar:	minirootfs
	tar --format=gnu -C $< -cf $@.tmp . 2>/dev/null || tar --format=pax -C $< -cf $@.tmp . 2>/dev/null
	mv $@.tmp $@
