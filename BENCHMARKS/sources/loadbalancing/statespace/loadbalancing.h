/* This file is automatically generated
   do not edit this file directly! */

#ifndef KAIRA_PROJECT_loadbalancing
#define KAIRA_PROJECT_loadbalancing
#include <cailie.h>
#include <algorithm>
#include <stdlib.h>
#include <stdio.h>
#include <sstream>

struct param
{
	static ca::ParameterInt JOBS;
};

#line 1 "*head"

int up(ca::Context &ctx) {
	return (ctx.process_id() + 1) % ctx.process_count();
}

int down(ca::Context &ctx) {
	return (ctx.process_id() - 1 + ctx.process_count()) % ctx.process_count();
}

#endif // KAIRA_PROJECT_loadbalancing
