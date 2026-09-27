#!/usr/bin/env python3
"""Generate U-Boot's drivers/pinctrl/qcom/pinctrl-ipq8074.c from Linux's
drivers/pinctrl/qcom/pinctrl-ipq8074.c, so the pin/function table is never
transcribed by hand. Output follows mainline's pinctrl-ipq9574.c layout.

usage: tools/gen-pinctrl-ipq8074.py <linux pinctrl-ipq8074.c> > pinctrl-ipq8074.c
"""
import re
import sys

src = open(sys.argv[1]).read()

enum = re.search(r"enum ipq8074_functions \{(.*?)\};", src, re.S).group(1)
functions = re.findall(r"msm_mux_(\w+)", enum)
assert "gpio" in functions and functions[-1] == "NA", functions[-3:]
functions = [f for f in functions if f != "NA"]

groups_block = re.search(r"ipq8074_groups\[\] = \{(.*?)\n\};", src, re.S).group(1)
groups = {}
for m in re.finditer(r"PINGROUP\((\d+),([^)]*)\)", groups_block):
    funcs = [f.strip() for f in m.group(2).split(",")]
    assert len(funcs) == 9, (m.group(1), funcs)
    groups[int(m.group(1))] = funcs
ngpios = int(re.search(r"\.ngpios = (\d+)", src).group(1))
assert sorted(groups) == list(range(ngpios)), "gap in PINGROUP table"
used = {f for fs in groups.values() for f in fs if f != "NA"}
assert used <= set(functions), used - set(functions)

out = []
w = out.append
w("// SPDX-License-Identifier: GPL-2.0")
w("/*")
w(" * pinctrl driver for Qualcomm IPQ8074")
w(" *")
w(" * Pin and function tables generated from Linux")
w(" * drivers/pinctrl/qcom/pinctrl-ipq8074.c (Copyright (c) 2017,")
w(" * The Linux Foundation) by tools/gen-pinctrl-ipq8074.py.")
w(" */")
w("")
w("#include <dm.h>")
w("")
w('#include "pinctrl-qcom.h"')
w("")
w("#define MAX_PIN_NAME_LEN 32")
w('static char pin_name[MAX_PIN_NAME_LEN] __section(".data");')
w("")
w("enum ipq8074_functions {")
for f in functions:
    w(f"\tmsm_mux_{f},")
w("\tmsm_mux_NA,")
w("};")
w("")
w("#define MSM_PIN_FUNCTION(fname)\t\t\t\t\\")
w("\t[msm_mux_##fname] = {#fname, msm_mux_##fname}")
w("")
w("static const struct pinctrl_function msm_pinctrl_functions[] = {")
for f in functions:
    w(f"\tMSM_PIN_FUNCTION({f}),")
w("};")
w("")
w("typedef unsigned int msm_pin_function[10];")
w("")
w("#define PINGROUP(id, f1, f2, f3, f4, f5, f6, f7, f8, f9) \\")
w("\t[id] = {        msm_mux_gpio, /* gpio mode */\t\\")
for i in range(1, 10):
    w(f"\t\t\tmsm_mux_##f{i},\t\t\t" + ("\\" if i < 9 else "\\"))
w("\t}")
w("")
w("static const msm_pin_function ipq8074_pin_functions[] = {")
for pin in range(ngpios):
    w(f"\tPINGROUP({pin}, {', '.join(groups[pin])}),")
w("};")
w("")
w("""static const char *ipq8074_get_function_name(struct udevice *dev,
					     unsigned int selector)
{
	return msm_pinctrl_functions[selector].name;
}

static const char *ipq8074_get_pin_name(struct udevice *dev,
					unsigned int selector)
{
	snprintf(pin_name, MAX_PIN_NAME_LEN, "gpio%u", selector);
	return pin_name;
}

static int ipq8074_get_function_mux(unsigned int pin, unsigned int selector)
{
	unsigned int i;
	const msm_pin_function *func = ipq8074_pin_functions + pin;

	for (i = 0; i < 10; i++)
		if ((*func)[i] == selector)
			return i;

	debug("Can't find requested function for pin:selector %u:%u\\n",
	      pin, selector);

	return -EINVAL;
}

static const struct msm_pinctrl_data ipq8074_data = {
	.pin_data = {
		.pin_count = %d,
	},
	.functions_count = ARRAY_SIZE(msm_pinctrl_functions),
	.get_function_name = ipq8074_get_function_name,
	.get_function_mux = ipq8074_get_function_mux,
	.get_pin_name = ipq8074_get_pin_name,
};

static const struct udevice_id msm_pinctrl_ids[] = {
	{ .compatible = "qcom,ipq8074-pinctrl", .data = (ulong)&ipq8074_data },
	{ /* Sentinel */ }
};

U_BOOT_DRIVER(pinctrl_ipq8074) = {
	.name		= "pinctrl_ipq8074",
	.id		= UCLASS_NOP,
	.of_match	= msm_pinctrl_ids,
	.ops		= &msm_pinctrl_ops,
	.bind		= msm_pinctrl_bind,
	.flags		= DM_FLAG_PRE_RELOC,
};""".replace("%d", str(ngpios)))
print("\n".join(out))
