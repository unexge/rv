fn make(k: u32, x: u32) -> Foo {
    let _ = chain_a()
        .step1()
        .step2();
    insert(Foo::wrap(k), v);
    Foo {
        field_a: wrap(x),
        field_b: Old::default(),
        extra: 1,
    }
}
