#![no_std]
#![no_main]
#![feature(global_asm, llvm_asm)]

#[macro_use]
mod console;

use core::panic::PanicInfo;

global_asm!(include_str!("entry.asm"));

#[no_mangle]
pub static mut SOME_N: u64 = 424242424242;

#[no_mangle]
pub static mut SOME_M: u32 = 200;

#[no_mangle]
pub static mut SOME_BITS: &'static [u8] = &[0x12, 0x34, 0x56, 0x78];

#[no_mangle]
pub static mut DIV_A: u32 = 231;

#[no_mangle]
pub static mut DIV_A_S: i32 = 231;

#[no_mangle]
pub static mut DIV_B: u32 = 40;

#[no_mangle]
pub static mut DIV_B_S: i32 = 40;

unsafe fn putchar(c: u8) {
    core::ptr::write_volatile(0xfe000000 as *mut u32, c as u32);
}

unsafe fn cycle() -> u64 {
    let low = core::ptr::read_volatile(0xfe000010 as *mut u32);
    let high = core::ptr::read_volatile(0xfe000014 as *mut u32);
    (low as u64) | ((high as u64) << 32)
}

#[no_mangle]
pub unsafe extern "C" fn rust_main() -> ! {
    // Comment cycle() out for co-simulation
    /*
    let start = cycle();
    println!("Hello world from Rust on Violet.");
    let end = cycle();
    println!("Previous println took {} cycles.", end - start);
    */

    println!("Some const 1: {}", SOME_N);
    println!("Some const 2: {}", SOME_M);

    println!("Mul A*B: {}", DIV_A * DIV_B);

    println!("UDiv A/B: {}", DIV_A / DIV_B);
    println!("URem A/B: {}", DIV_A % DIV_B);

    println!("SDiv A/B: {}", DIV_A_S / DIV_B_S);
    println!("SRem A/B: {}", DIV_A_S % DIV_B_S);

    println!("SDiv -A/B: {}", -DIV_A_S / DIV_B_S);
    println!("SRem -A/B: {}", -DIV_A_S % DIV_B_S);

    println!("SDiv A/-B: {}", DIV_A_S / -DIV_B_S);
    println!("SRem A/-B: {}", DIV_A_S % -DIV_B_S);

    println!("SDiv -A/-B: {}", -DIV_A_S / -DIV_B_S);
    println!("SRem -A/-B: {}", -DIV_A_S % -DIV_B_S);

    loop {
        llvm_asm!("" :::: "volatile");
    }
}

#[panic_handler]
fn on_panic(info: &PanicInfo) -> ! {
    loop {}
}
