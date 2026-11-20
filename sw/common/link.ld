OUTPUT_ARCH( "riscv" )
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4M }
SECTIONS
{
  .text : { *(.text.init) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .tohost : { . = ALIGN(64); *(.tohost) } > RAM
  .data : { . = ALIGN(16); PROVIDE(__global_pointer$ = . + 0x800); *(.data .data.* .sdata .sdata.*) } > RAM
  .bss : { . = ALIGN(16); __bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN(4); __bss_end = .; } > RAM
  . = ALIGN(16);
  _end = .;
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
