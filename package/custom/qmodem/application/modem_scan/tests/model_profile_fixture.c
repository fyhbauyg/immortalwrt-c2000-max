/* Exercise the scanner's real model parser and profile lookup without AT I/O. */
#define main modem_scand_main
#include "../src/modem_scand.c"
#undef main
#include <assert.h>

static int profile_from_reply(const char *reply, struct modem_profile *profile)
{
	struct str_list names;
	sl_init(&names);
	assert(extract_candidate_lines(reply, &names) == 0);
	for (size_t i = 0; i < names.len; i++) {
		char name[128];
		snprintf(name, sizeof(name), "%s", names.items[i]);
		normalize_model_name(name, sizeof(name));
		if (load_profile("usb", name, profile) == 0) {
			sl_free(&names);
			return 0;
		}
	}
	sl_free(&names);
	return -1;
}

int main(int argc, char **argv)
{
	assert(argc == 2);
	g.support_json = json_object_from_file(argv[1]);
	assert(g.support_json);
	json_object *support, *usb, *saved;
	assert(json_get_obj(g.support_json, "modem_support", &support));
	assert(json_get_obj(support, "usb", &usb));
	assert(json_get_obj(usb, "srm825l", &saved));
	json_object_get(saved);

	/* Redacted replies from the failing router: both configured AT ports work. */
	const char *replies[] = {
		"AT+CGMM\r\n\r\n+CGMM: SRM825L\r\n\r\nOK\r\n",
		"ATI\r\nManufacturer: MEIG INCORPORATED\r\nModel: SRM825L\r\n"
		"Revision: SRM825L_6.0.5_EQ100\r\nOK\r\n",
	};
	struct modem_profile profile;
	json_object_object_del(usb, "srm825l");
	for (size_t i = 0; i < sizeof(replies) / sizeof(replies[0]); i++)
		assert(profile_from_reply(replies[i], &profile) != 0);
	json_object_object_add(usb, "srm825l", saved);
	for (size_t i = 0; i < sizeof(replies) / sizeof(replies[0]); i++) {
		assert(profile_from_reply(replies[i], &profile) == 0);
		assert(strcmp(profile.name, "srm825l") == 0);
		assert(strcmp(profile.manufacturer, "meig") == 0);
		assert(strcmp(profile.platform, "qualcomm") == 0);
		assert(strcmp(profile.pdp_index, "1") == 0);
		assert(sl_contains(&profile.modes, "ecm"));
		sl_free(&profile.modes);
	}
	assert(profile_from_reply("+CGMM: SRM825\r\nOK\r\n", &profile) == 0);
	assert(strcmp(profile.name, "srm825") == 0);
	sl_free(&profile.modes);
	assert(profile_from_reply("+CGMM: SRM825N\r\nOK\r\n", &profile) == 0);
	assert(strcmp(profile.name, "srm825n") == 0);
	sl_free(&profile.modes);
	assert(profile_from_reply("+CGMM: SRM825-UNKNOWN\r\nOK\r\n", &profile) != 0);
	json_object_put(g.support_json);
	puts("PASS: missing SRM825L reproduced; CGMM/ATI match with new profile; SRM825/N unchanged");
	return 0;
}
