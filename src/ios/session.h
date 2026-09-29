/* The Wine session: Wine boots once per app run, with the session host
 * (src/session/session.c) as its root process, and every program the Library
 * starts runs in it. The host's display-driver thread takes programs from this
 * queue; the server counts the ones running. */
#ifndef IOSWINE_SESSION_H
#define IOSWINE_SESSION_H

#import <Foundation/Foundation.h>

/* The session host in the app bundle. */
NSString *IOSWineSessionHostPath(void);

/* Queues a program for the session host. argv starts with the program; its
 * path and other paths on the phone become Windows paths. NO when the command
 * line does not fit. Any thread. */
BOOL IOSWineSessionQueue(NSArray<NSString *> *argv, NSString *cwd);

/* Programs running in the session, not counting the host. */
int IOSWineSessionPrograms(void);

#endif
